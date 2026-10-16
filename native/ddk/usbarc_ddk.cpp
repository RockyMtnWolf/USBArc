#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#include <node_api.h>
#include <usb/usb_ddk_api.h>
#include <usb/usb_ddk_types.h>

namespace {

struct ClaimedInterface {
    uint64_t deviceId;
    uint64_t handle;
};

std::mutex g_mutex;
std::unordered_map<std::string, ClaimedInterface> g_claims;
uint64_t g_nextClaimId = 1;
bool g_initialized = false;

bool GetString(napi_env env, napi_value value, std::string &result)
{
    size_t size = 0;
    if (napi_get_value_string_utf8(env, value, nullptr, 0, &size) != napi_ok) {
        return false;
    }
    std::vector<char> buffer(size + 1, '\0');
    if (napi_get_value_string_utf8(env, value, buffer.data(), buffer.size(), &size) != napi_ok) {
        return false;
    }
    result.assign(buffer.data(), size);
    return true;
}

bool GetUint32(napi_env env, napi_value value, uint32_t &result)
{
    int32_t parsed = 0;
    if (napi_get_value_int32(env, value, &parsed) != napi_ok || parsed < 0) {
        return false;
    }
    result = static_cast<uint32_t>(parsed);
    return true;
}

bool GetUint64String(napi_env env, napi_value value, uint64_t &result)
{
    std::string text;
    if (!GetString(env, value, text) || text.empty()) {
        return false;
    }
    char *end = nullptr;
    const unsigned long long parsed = std::strtoull(text.c_str(), &end, 10);
    if (end == text.c_str() || *end != '\0') {
        return false;
    }
    result = static_cast<uint64_t>(parsed);
    return true;
}

bool GetNumberArray(napi_env env, napi_value value, std::vector<uint8_t> &result)
{
    bool isArray = false;
    if (napi_is_array(env, value, &isArray) != napi_ok || !isArray) {
        return false;
    }
    uint32_t length = 0;
    if (napi_get_array_length(env, value, &length) != napi_ok || length > 8000) {
        return false;
    }
    result.resize(length);
    for (uint32_t index = 0; index < length; ++index) {
        napi_value item = nullptr;
        uint32_t byte = 0;
        if (napi_get_element(env, value, index, &item) != napi_ok || !GetUint32(env, item, byte) || byte > 255) {
            return false;
        }
        result[index] = static_cast<uint8_t>(byte);
    }
    return true;
}

napi_value CreateNumber(napi_env env, uint32_t number)
{
    napi_value value = nullptr;
    napi_create_uint32(env, number, &value);
    return value;
}

napi_value CreateSignedNumber(napi_env env, int32_t number)
{
    napi_value value = nullptr;
    napi_create_int32(env, number, &value);
    return value;
}

napi_value CreateString(napi_env env, const std::string &text)
{
    napi_value value = nullptr;
    napi_create_string_utf8(env, text.c_str(), text.size(), &value);
    return value;
}

napi_value CreateArray(napi_env env, const std::vector<uint8_t> &bytes)
{
    napi_value array = nullptr;
    if (napi_create_array_with_length(env, bytes.size(), &array) != napi_ok) {
        return nullptr;
    }
    for (uint32_t index = 0; index < bytes.size(); ++index) {
        napi_set_element(env, array, index, CreateNumber(env, bytes[index]));
    }
    return array;
}

napi_value CreateResult(napi_env env, int32_t status, napi_value value = nullptr)
{
    napi_value result = nullptr;
    napi_create_object(env, &result);
    napi_set_named_property(env, result, "status", CreateSignedNumber(env, status));
    if (value != nullptr) {
        napi_set_named_property(env, result, "value", value);
    }
    return result;
}

napi_value CreateTransferResult(napi_env env, int32_t status, uint32_t actualLength,
    const std::vector<uint8_t> &bytes)
{
    napi_value result = nullptr;
    napi_create_object(env, &result);
    napi_set_named_property(env, result, "status", CreateSignedNumber(env, status));
    napi_set_named_property(env, result, "actualLength", CreateNumber(env, actualLength));
    napi_set_named_property(env, result, "data", CreateArray(env, bytes));
    return result;
}

bool AppendExtra(std::vector<uint8_t> &target, const uint8_t *bytes, uint32_t length)
{
    constexpr size_t kMaxDescriptorBytes = 8000;
    if (length == 0) return true;
    if (bytes == nullptr || length > kMaxDescriptorBytes - target.size()) return false;
    size_t offset = 0;
    while (offset < length) {
        if (static_cast<size_t>(length) - offset < 2) return false;
        const uint8_t descriptorLength = bytes[offset];
        if (descriptorLength < 2 || descriptorLength > static_cast<size_t>(length) - offset) return false;
        offset += descriptorLength;
    }
    target.insert(target.end(), bytes, bytes + length);
    return true;
}

void AppendLe16(std::vector<uint8_t> &target, uint16_t value)
{
    target.push_back(static_cast<uint8_t>(value & 0xff));
    target.push_back(static_cast<uint8_t>((value >> 8) & 0xff));
}

bool BuildConfigurationBytes(const UsbDdkConfigDescriptor &config, std::vector<uint8_t> &bytes)
{
    constexpr size_t kMaxDescriptorBytes = 8000;
    const UsbConfigDescriptor &standard = config.configDescriptor;
    if (standard.bNumInterfaces > 0 && config.interface == nullptr) return false;
    if (bytes.size() > kMaxDescriptorBytes - 9) return false;
    bytes.insert(bytes.end(), {9, 2, 0, 0, standard.bNumInterfaces, standard.bConfigurationValue,
        standard.iConfiguration, standard.bmAttributes, standard.bMaxPower});
    if (!AppendExtra(bytes, config.extra, config.extraLength)) return false;

    for (uint32_t interfaceIndex = 0; interfaceIndex < standard.bNumInterfaces; ++interfaceIndex) {
        const UsbDdkInterface &interface = config.interface[interfaceIndex];
        if (interface.numAltsetting == 0 || interface.altsetting == nullptr) return false;
        for (uint32_t alternateIndex = 0; alternateIndex < interface.numAltsetting; ++alternateIndex) {
            const UsbDdkInterfaceDescriptor &alternate = interface.altsetting[alternateIndex];
            const UsbInterfaceDescriptor &interfaceDescriptor = alternate.interfaceDescriptor;
            if (interfaceDescriptor.bNumEndpoints > 0 && alternate.endPoint == nullptr) return false;
            if (bytes.size() > kMaxDescriptorBytes - 9) return false;
            bytes.insert(bytes.end(), {9, 4, interfaceDescriptor.bInterfaceNumber,
                interfaceDescriptor.bAlternateSetting, interfaceDescriptor.bNumEndpoints,
                interfaceDescriptor.bInterfaceClass, interfaceDescriptor.bInterfaceSubClass,
                interfaceDescriptor.bInterfaceProtocol, interfaceDescriptor.iInterface});
            if (bytes.size() > kMaxDescriptorBytes || !AppendExtra(bytes, alternate.extra, alternate.extraLength)) return false;
            for (uint32_t endpointIndex = 0; endpointIndex < interfaceDescriptor.bNumEndpoints; ++endpointIndex) {
                const UsbDdkEndpointDescriptor &endpoint = alternate.endPoint[endpointIndex];
                const UsbEndpointDescriptor &endpointDescriptor = endpoint.endpointDescriptor;
                const uint8_t endpointLength = endpointDescriptor.bLength >= 9 ? 9 : 7;
                if (bytes.size() > kMaxDescriptorBytes - endpointLength) return false;
                bytes.push_back(endpointLength);
                bytes.push_back(5);
                bytes.push_back(endpointDescriptor.bEndpointAddress);
                bytes.push_back(endpointDescriptor.bmAttributes);
                AppendLe16(bytes, endpointDescriptor.wMaxPacketSize);
                bytes.push_back(endpointDescriptor.bInterval);
                if (endpointLength >= 9) {
                    bytes.push_back(endpointDescriptor.bRefresh);
                    bytes.push_back(endpointDescriptor.bSynchAddress);
                }
                if (bytes.size() > kMaxDescriptorBytes || !AppendExtra(bytes, endpoint.extra, endpoint.extraLength)) return false;
            }
        }
    }
    if (bytes.size() < 9 || bytes.size() > kMaxDescriptorBytes || bytes.size() > UINT16_MAX) return false;
    const uint16_t length = static_cast<uint16_t>(bytes.size());
    bytes[2] = static_cast<uint8_t>(length & 0xff);
    bytes[3] = static_cast<uint8_t>((length >> 8) & 0xff);
    return true;
}

bool IsControlTransferError(int32_t result)
{
    return result < 0 || result == USB_DDK_NO_PERM || result == USB_DDK_INVALID_PARAMETER ||
        result == USB_DDK_MEMORY_ERROR || result == USB_DDK_INVALID_OPERATION ||
        result == USB_DDK_IO_FAILED || result == USB_DDK_TIMEOUT;
}

napi_value IsInitialized(napi_env env, napi_callback_info info)
{
    (void)info;
    napi_value result = nullptr;
    napi_get_boolean(env, g_initialized, &result);
    return result;
}

napi_value InitDdk(napi_env env, napi_callback_info info)
{
    (void)info;
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_initialized) {
        return CreateSignedNumber(env, USB_DDK_SUCCESS);
    }
    const int32_t result = OH_Usb_Init();
    g_initialized = result == USB_DDK_SUCCESS;
    return CreateSignedNumber(env, result);
}

napi_value ReleaseDdk(napi_env env, napi_callback_info info)
{
    (void)info;
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_initialized) {
        return CreateSignedNumber(env, USB_DDK_SUCCESS);
    }
    int32_t releaseStatus = USB_DDK_SUCCESS;
    for (auto iterator = g_claims.begin(); iterator != g_claims.end();) {
        const int32_t status = OH_Usb_ReleaseInterface(iterator->second.handle);
        if (status == USB_DDK_SUCCESS) {
            iterator = g_claims.erase(iterator);
        } else {
            if (releaseStatus == USB_DDK_SUCCESS) releaseStatus = status;
            ++iterator;
        }
    }
    if (releaseStatus != USB_DDK_SUCCESS) return CreateSignedNumber(env, releaseStatus);
    const int32_t result = OH_Usb_ReleaseResource();
    if (result == USB_DDK_SUCCESS) g_initialized = false;
    return CreateSignedNumber(env, result);
}

napi_value GetDevices(napi_env env, napi_callback_info info)
{
    (void)info;
    if (!g_initialized) {
        return CreateResult(env, USB_DDK_INVALID_OPERATION);
    }
    constexpr uint32_t kMaxDevices = 128;
    std::vector<uint64_t> ids(kMaxDevices, 0);
    Usb_DeviceArray devices {};
    devices.deviceIds = ids.data();
    devices.num = 0;
    const int32_t status = OH_Usb_GetDevices(&devices);
    if (status != USB_DDK_SUCCESS) {
        return CreateResult(env, status);
    }
    if (devices.num > kMaxDevices) {
        return CreateResult(env, USB_DDK_INVALID_PARAMETER);
    }
    napi_value values = nullptr;
    napi_create_array_with_length(env, devices.num, &values);
    for (uint32_t index = 0; index < devices.num; ++index) {
        napi_set_element(env, values, index, CreateString(env, std::to_string(ids[index])));
    }
    return CreateResult(env, USB_DDK_SUCCESS, values);
}

napi_value GetDeviceDescriptor(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint64_t deviceId = 0;
    if (argc != 1 || !GetUint64String(env, argv[0], deviceId)) {
        return CreateResult(env, USB_DDK_INVALID_PARAMETER);
    }
    UsbDeviceDescriptor descriptor {};
    const int32_t status = OH_Usb_GetDeviceDescriptor(deviceId, &descriptor);
    if (status != USB_DDK_SUCCESS) {
        return CreateResult(env, status);
    }
    std::vector<uint8_t> bytes;
    bytes.push_back(descriptor.bLength);
    bytes.push_back(descriptor.bDescriptorType);
    AppendLe16(bytes, descriptor.bcdUSB);
    bytes.push_back(descriptor.bDeviceClass);
    bytes.push_back(descriptor.bDeviceSubClass);
    bytes.push_back(descriptor.bDeviceProtocol);
    bytes.push_back(descriptor.bMaxPacketSize0);
    AppendLe16(bytes, descriptor.idVendor);
    AppendLe16(bytes, descriptor.idProduct);
    AppendLe16(bytes, descriptor.bcdDevice);
    bytes.push_back(descriptor.iManufacturer);
    bytes.push_back(descriptor.iProduct);
    bytes.push_back(descriptor.iSerialNumber);
    bytes.push_back(descriptor.bNumConfigurations);
    napi_value value = nullptr;
    napi_create_object(env, &value);
    napi_set_named_property(env, value, "id", CreateString(env, std::to_string(deviceId)));
    napi_set_named_property(env, value, "bytes", CreateArray(env, bytes));
    napi_set_named_property(env, value, "vendorId", CreateNumber(env, descriptor.idVendor));
    napi_set_named_property(env, value, "productId", CreateNumber(env, descriptor.idProduct));
    napi_set_named_property(env, value, "deviceClass", CreateNumber(env, descriptor.bDeviceClass));
    napi_set_named_property(env, value, "deviceSubClass", CreateNumber(env, descriptor.bDeviceSubClass));
    napi_set_named_property(env, value, "deviceProtocol", CreateNumber(env, descriptor.bDeviceProtocol));
    napi_set_named_property(env, value, "bcdUsb", CreateNumber(env, descriptor.bcdUSB));
    napi_set_named_property(env, value, "bcdDevice", CreateNumber(env, descriptor.bcdDevice));
    napi_set_named_property(env, value, "maxPacketSize0", CreateNumber(env, descriptor.bMaxPacketSize0));
    napi_set_named_property(env, value, "configurationCount", CreateNumber(env, descriptor.bNumConfigurations));
    return CreateResult(env, USB_DDK_SUCCESS, value);
}

int32_t ReadConfigurationValue(uint64_t deviceId, uint8_t descriptorIndex, uint8_t &configurationValue)
{
    UsbControlRequestSetup request {};
    request.bmRequestType = 0x80;
    request.bRequest = 6; // GET_DESCRIPTOR
    request.wValue = static_cast<uint16_t>((2U << 8) | descriptorIndex);
    request.wLength = 9;
    uint8_t bytes[9] {};
    const int32_t status = OH_Usb_ControlTransfer(deviceId, &request, bytes, 5000);
    if (status != 9) return status < 0 || status > 9 ? status : USB_DDK_IO_FAILED;
    if (bytes[0] < 9 || bytes[1] != 2 || bytes[5] == 0) return USB_DDK_IO_FAILED;
    configurationValue = bytes[5];
    return USB_DDK_SUCCESS;
}

napi_value GetActiveConfiguration(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint64_t deviceId = 0;
    if (argc != 1 || !GetUint64String(env, argv[0], deviceId)) {
        return CreateResult(env, USB_DDK_INVALID_PARAMETER);
    }
    if (!g_initialized) return CreateResult(env, USB_DDK_INVALID_OPERATION);
    UsbControlRequestSetup request {};
    request.bmRequestType = 0x80;
    request.bRequest = 8; // GET_CONFIGURATION
    request.wLength = 1;
    uint8_t value = 0;
    const int32_t status = OH_Usb_ControlTransfer(deviceId, &request, &value, 5000);
    if (status != 1 || value == 0) return CreateResult(env, status == 1 ? USB_DDK_IO_FAILED : status);
    napi_value result = nullptr;
    napi_create_object(env, &result);
    napi_set_named_property(env, result, "configurationValue", CreateNumber(env, value));
    return CreateResult(env, USB_DDK_SUCCESS, result);
}

napi_value GetConfigDescriptor(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint64_t deviceId = 0;
    uint32_t descriptorIndex = 0;
    if (argc != 2 || !GetUint64String(env, argv[0], deviceId) || !GetUint32(env, argv[1], descriptorIndex) || descriptorIndex > 255) {
        return CreateResult(env, USB_DDK_INVALID_PARAMETER);
    }
    if (!g_initialized) return CreateResult(env, USB_DDK_INVALID_OPERATION);
    uint8_t configValue = 0;
    const int32_t descriptorStatus = ReadConfigurationValue(deviceId, static_cast<uint8_t>(descriptorIndex), configValue);
    if (descriptorStatus != USB_DDK_SUCCESS) return CreateResult(env, descriptorStatus);
    UsbDdkConfigDescriptor *config = nullptr;
    const int32_t status = OH_Usb_GetConfigDescriptor(deviceId, configValue, &config);
    if (status != USB_DDK_SUCCESS || config == nullptr) {
        return CreateResult(env, status == USB_DDK_SUCCESS ? USB_DDK_IO_FAILED : status);
    }
    std::vector<uint8_t> bytes;
    if (!BuildConfigurationBytes(*config, bytes)) {
        OH_Usb_FreeConfigDescriptor(config);
        return CreateResult(env, USB_DDK_INVALID_PARAMETER);
    }
    napi_value value = nullptr;
    napi_create_object(env, &value);
    napi_set_named_property(env, value, "configurationValue", CreateNumber(env, config->configDescriptor.bConfigurationValue));
    napi_set_named_property(env, value, "attributes", CreateNumber(env, config->configDescriptor.bmAttributes));
    napi_set_named_property(env, value, "maxPower", CreateNumber(env, config->configDescriptor.bMaxPower));
    napi_set_named_property(env, value, "interfaceCount", CreateNumber(env, config->configDescriptor.bNumInterfaces));
    napi_set_named_property(env, value, "bytes", CreateArray(env, bytes));
    OH_Usb_FreeConfigDescriptor(config);
    return CreateResult(env, USB_DDK_SUCCESS, value);
}

napi_value ClaimInterface(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint64_t deviceId = 0;
    uint32_t interfaceNumber = 0;
    if (argc != 2 || !GetUint64String(env, argv[0], deviceId) || !GetUint32(env, argv[1], interfaceNumber) || interfaceNumber > 255) {
        return CreateResult(env, USB_DDK_INVALID_PARAMETER);
    }
    if (!g_initialized) return CreateResult(env, USB_DDK_INVALID_OPERATION);
    uint64_t handle = 0;
    const int32_t status = OH_Usb_ClaimInterface(deviceId, static_cast<uint8_t>(interfaceNumber), &handle);
    if (status != USB_DDK_SUCCESS) {
        return CreateResult(env, status);
    }
    std::lock_guard<std::mutex> lock(g_mutex);
    const std::string token = std::to_string(g_nextClaimId++);
    g_claims.emplace(token, ClaimedInterface {deviceId, handle});
    return CreateResult(env, USB_DDK_SUCCESS, CreateString(env, token));
}

bool FindClaim(napi_env env, napi_value value, std::string &token, ClaimedInterface &claim)
{
    if (!GetString(env, value, token)) {
        return false;
    }
    std::lock_guard<std::mutex> lock(g_mutex);
    const auto found = g_claims.find(token);
    if (found == g_claims.end()) {
        return false;
    }
    claim = found->second;
    return true;
}

napi_value ReleaseInterface(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc != 1) {
        return CreateSignedNumber(env, USB_DDK_INVALID_PARAMETER);
    }
    std::string token;
    if (!GetString(env, argv[0], token)) {
        return CreateSignedNumber(env, USB_DDK_INVALID_PARAMETER);
    }
    std::lock_guard<std::mutex> lock(g_mutex);
    const auto found = g_claims.find(token);
    if (found == g_claims.end()) {
        return CreateSignedNumber(env, USB_DDK_INVALID_OPERATION);
    }
    const int32_t status = OH_Usb_ReleaseInterface(found->second.handle);
    if (status == USB_DDK_SUCCESS) g_claims.erase(found);
    return CreateSignedNumber(env, status);
}

napi_value SelectInterfaceSetting(napi_env env, napi_callback_info info)
{
    size_t argc = 2;
    napi_value argv[2] = {nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    if (argc != 2) {
        return CreateSignedNumber(env, USB_DDK_INVALID_PARAMETER);
    }
    std::string token;
    ClaimedInterface claim {};
    uint32_t alternate = 0;
    if (!FindClaim(env, argv[0], token, claim) || !GetUint32(env, argv[1], alternate) || alternate > 255) {
        return CreateSignedNumber(env, USB_DDK_INVALID_PARAMETER);
    }
    const int32_t status = OH_Usb_SelectInterfaceSetting(claim.handle, static_cast<uint8_t>(alternate));
    return CreateSignedNumber(env, status);
}

napi_value ControlTransfer(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value argv[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    uint64_t deviceId = 0;
    uint32_t timeout = 0;
    std::vector<uint8_t> setup;
    std::vector<uint8_t> data;
    if (argc != 4 || !GetUint64String(env, argv[0], deviceId) || !GetNumberArray(env, argv[1], setup) ||
        setup.size() != 8 || !GetNumberArray(env, argv[2], data) || !GetUint32(env, argv[3], timeout)) {
        return CreateTransferResult( env, USB_DDK_INVALID_PARAMETER, 0, {});
    }
    UsbControlRequestSetup request {};
    request.bmRequestType = setup[0];
    request.bRequest = setup[1];
    request.wValue = static_cast<uint16_t>(setup[2] | (static_cast<uint16_t>(setup[3]) << 8));
    request.wIndex = static_cast<uint16_t>(setup[4] | (static_cast<uint16_t>(setup[5]) << 8));
    request.wLength = static_cast<uint16_t>(setup[6] | (static_cast<uint16_t>(setup[7]) << 8));
    if (request.wLength > 1024 || data.size() < request.wLength) {
        return CreateTransferResult(env, USB_DDK_INVALID_PARAMETER, 0, {});
    }
    timeout = timeout == 0 ? 10000 : std::min<uint32_t>(timeout, 30000);
    data.resize(request.wLength);
    if (data.empty()) {
        data.resize(1, 0);
    }
    const int32_t status = OH_Usb_ControlTransfer(deviceId, &request, data.data(), timeout);
    if (IsControlTransferError(status) || static_cast<uint32_t>(status) > request.wLength) {
        return CreateTransferResult(env, status, 0, {});
    }
    const uint32_t actualLength = std::min<uint32_t>(static_cast<uint32_t>(status), request.wLength);
    data.resize(actualLength);
    const bool input = (request.bmRequestType & 0x80U) != 0;
    return CreateTransferResult(env, USB_DDK_SUCCESS, actualLength, input ? data : std::vector<uint8_t> {});
}

napi_value ClaimedControlTransfer(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value argv[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    std::string token;
    ClaimedInterface claim {};
    uint32_t timeout = 0;
    std::vector<uint8_t> setup;
    std::vector<uint8_t> data;
    if (argc != 4 || !FindClaim(env, argv[0], token, claim) || !GetNumberArray(env, argv[1], setup) ||
        setup.size() != 8 || !GetNumberArray(env, argv[2], data) || !GetUint32(env, argv[3], timeout)) {
        return CreateTransferResult(env, USB_DDK_INVALID_PARAMETER, 0, {});
    }
    UsbControlRequestSetup request {};
    request.bmRequestType = setup[0];
    request.bRequest = setup[1];
    request.wValue = static_cast<uint16_t>(setup[2] | (static_cast<uint16_t>(setup[3]) << 8));
    request.wIndex = static_cast<uint16_t>(setup[4] | (static_cast<uint16_t>(setup[5]) << 8));
    request.wLength = static_cast<uint16_t>(setup[6] | (static_cast<uint16_t>(setup[7]) << 8));
    if (request.wLength > 1024 || data.size() < request.wLength) {
        return CreateTransferResult(env, USB_DDK_INVALID_PARAMETER, 0, {});
    }
    timeout = timeout == 0 ? 10000 : std::min<uint32_t>(timeout, 30000);
    data.resize(std::max<size_t>(request.wLength, 1), 0);
    int32_t status = USB_DDK_SUCCESS;
    uint32_t actualLength = request.wLength;
    if ((request.bmRequestType & 0x80U) != 0) {
        status = OH_Usb_SendControlReadRequest(claim.handle, &request, timeout, data.data(), &actualLength);
        if (actualLength > request.wLength) {
            return CreateTransferResult(env, USB_DDK_INVALID_PARAMETER, 0, {});
        }
        data.resize(actualLength);
    } else {
        status = OH_Usb_SendControlWriteRequest(claim.handle, &request, timeout, data.data(), request.wLength);
        actualLength = status == USB_DDK_SUCCESS ? request.wLength : 0;
        data.resize(actualLength);
    }
    const bool input = (request.bmRequestType & 0x80U) != 0;
    return CreateTransferResult(env, status, actualLength,
        status == USB_DDK_SUCCESS && input ? data : std::vector<uint8_t> {});
}

napi_value PipeTransfer(napi_env env, napi_callback_info info)
{
    size_t argc = 4;
    napi_value argv[4] = {nullptr, nullptr, nullptr, nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    std::string token;
    ClaimedInterface claim {};
    uint32_t endpoint = 0;
    uint32_t timeout = 0;
    std::vector<uint8_t> data;
    if (argc != 4 || !FindClaim(env, argv[0], token, claim) || !GetUint32(env, argv[1], endpoint) || endpoint > 255 ||
        !GetNumberArray(env, argv[2], data) || !GetUint32(env, argv[3], timeout) || data.size() > 8000) {
        return CreateTransferResult(env, USB_DDK_INVALID_PARAMETER, 0, {});
    }
    const size_t capacity = std::max<size_t>(data.size(), 1);
    timeout = timeout == 0 ? 10000 : std::min<uint32_t>(timeout, 30000);
    UsbDeviceMemMap *memory = nullptr;
    const int32_t createStatus = OH_Usb_CreateDeviceMemMap(claim.deviceId, capacity, &memory);
    if (createStatus != USB_DDK_SUCCESS || memory == nullptr || memory->address == nullptr) {
        return CreateTransferResult(env, createStatus == USB_DDK_SUCCESS ? USB_DDK_MEMORY_ERROR : createStatus, 0, {});
    }
    const bool input = (endpoint & 0x80U) != 0;
    if (!input && !data.empty()) {
        std::memcpy(memory->address, data.data(), data.size());
    }
    memory->offset = 0;
    memory->bufferLength = static_cast<uint32_t>(data.size());
    memory->transferedLength = 0;
    UsbRequestPipe pipe {};
    pipe.interfaceHandle = claim.handle;
    pipe.timeout = timeout;
    pipe.endpoint = static_cast<uint8_t>(endpoint);
    int32_t status = OH_Usb_SendPipeRequest(&pipe, memory);
    std::vector<uint8_t> response;
    uint32_t actualLength = 0;
    if (status == USB_DDK_SUCCESS) {
        if (memory->offset > memory->bufferLength ||
            memory->transferedLength > memory->bufferLength - memory->offset) {
            status = -75; // EOVERFLOW: never truncate a device-reported transfer length.
        } else {
            actualLength = memory->transferedLength;
        }
    }
    if (input && actualLength > 0) {
        response.assign(memory->address + memory->offset, memory->address + memory->offset + actualLength);
    }
    OH_Usb_DestroyDeviceMemMap(memory);
    return CreateTransferResult(env, status, actualLength, response);
}

napi_value Init(napi_env env, napi_value exports)
{
    napi_property_descriptor functions[] = {
        {"init", nullptr, InitDdk, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isInitialized", nullptr, IsInitialized, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"release", nullptr, ReleaseDdk, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getDevices", nullptr, GetDevices, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getDeviceDescriptor", nullptr, GetDeviceDescriptor, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getActiveConfiguration", nullptr, GetActiveConfiguration, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getConfigDescriptor", nullptr, GetConfigDescriptor, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"claimInterface", nullptr, ClaimInterface, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"releaseInterface", nullptr, ReleaseInterface, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"selectInterfaceSetting", nullptr, SelectInterfaceSetting, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"controlTransfer", nullptr, ControlTransfer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"claimedControlTransfer", nullptr, ClaimedControlTransfer, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"pipeTransfer", nullptr, PipeTransfer, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_define_properties(env, exports, sizeof(functions) / sizeof(functions[0]), functions);
    return exports;
}

} // namespace

NAPI_MODULE(usbarc_ddk, Init)
