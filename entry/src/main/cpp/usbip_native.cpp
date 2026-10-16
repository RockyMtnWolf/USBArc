#include <cerrno>
#include <arpa/inet.h>
#include <cstdint>
#include <cstring>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <string>
#include <sys/ioctl.h>
#include <unistd.h>

#include <linux/usbdevice_fs.h>
#include <node_api.h>

namespace {

napi_value GetUsbSpeed(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    int32_t fd = -1;
    if (argc != 1 || napi_get_value_int32(env, argv[0], &fd) != napi_ok || fd < 0) {
        napi_value unknown;
        napi_create_int32(env, 0, &unknown);
        return unknown;
    }

    // USBDEVFS_GET_SPEED only reads the negotiated bus speed; it does not claim
    // interfaces, change configuration, or close the USBManager-owned fd.
    const int speed = ioctl(fd, USBDEVFS_GET_SPEED);
    napi_value result;
    napi_create_int32(env, speed >= 1 && speed <= 6 ? speed : 0, &result);
    return result;
}

uint32_t CountMaskBits(const uint8_t *mask, size_t length)
{
    uint32_t prefix = 0;
    for (size_t index = 0; index < length; ++index) {
        for (uint8_t bit = 0x80; bit != 0; bit >>= 1) {
            if ((mask[index] & bit) == 0) {
                return prefix;
            }
            ++prefix;
        }
    }
    return prefix;
}

bool SetNamedString(napi_env env, napi_value object, const char *name, const std::string &value)
{
    napi_value property = nullptr;
    if (napi_create_string_utf8(env, value.c_str(), value.length(), &property) != napi_ok) {
        return false;
    }
    return napi_set_named_property(env, object, name, property) == napi_ok;
}

bool SetNamedInt(napi_env env, napi_value object, const char *name, int32_t value)
{
    napi_value property = nullptr;
    if (napi_create_int32(env, value, &property) != napi_ok) {
        return false;
    }
    return napi_set_named_property(env, object, name, property) == napi_ok;
}

bool SetNamedBool(napi_env env, napi_value object, const char *name, bool value)
{
    napi_value property = nullptr;
    if (napi_get_boolean(env, value, &property) != napi_ok) {
        return false;
    }
    return napi_set_named_property(env, object, name, property) == napi_ok;
}

napi_value GetInterfaceAddresses(napi_env env, napi_callback_info info)
{
    (void)info;
    napi_value result = nullptr;
    if (napi_create_array(env, &result) != napi_ok) {
        return nullptr;
    }

    ifaddrs *interfaces = nullptr;
    if (getifaddrs(&interfaces) != 0) {
        const int error = errno;
        napi_throw_error(env, std::to_string(error).c_str(), "getifaddrs failed");
        return nullptr;
    }
    if (interfaces == nullptr) {
        return result;
    }

    uint32_t index = 0;
    for (const ifaddrs *entry = interfaces; entry != nullptr; entry = entry->ifa_next) {
        if (entry->ifa_addr == nullptr || entry->ifa_name == nullptr || (entry->ifa_flags & IFF_UP) == 0) {
            continue;
        }

        const int family = entry->ifa_addr->sa_family;
        const void *addressBytes = nullptr;
        const void *maskBytes = nullptr;
        size_t addressLength = 0;
        bool loopbackAddress = false;
        uint32_t scopeId = 0;
        char addressText[INET6_ADDRSTRLEN] = {};

        if (family == AF_INET) {
            const auto *address = reinterpret_cast<const sockaddr_in *>(entry->ifa_addr);
            addressBytes = &address->sin_addr;
            addressLength = sizeof(address->sin_addr);
            if (entry->ifa_netmask != nullptr) {
                maskBytes = &reinterpret_cast<const sockaddr_in *>(entry->ifa_netmask)->sin_addr;
            }
            const uint32_t hostAddress = ntohl(address->sin_addr.s_addr);
            loopbackAddress = (hostAddress >> 24) == 127;
        } else if (family == AF_INET6) {
            const auto *address = reinterpret_cast<const sockaddr_in6 *>(entry->ifa_addr);
            addressBytes = &address->sin6_addr;
            addressLength = sizeof(address->sin6_addr);
            if (entry->ifa_netmask != nullptr) {
                maskBytes = &reinterpret_cast<const sockaddr_in6 *>(entry->ifa_netmask)->sin6_addr;
            }
            loopbackAddress = IN6_IS_ADDR_LOOPBACK(&address->sin6_addr);
            scopeId = address->sin6_scope_id;
        } else {
            continue;
        }

        if (inet_ntop(family, addressBytes, addressText, sizeof(addressText)) == nullptr) {
            continue;
        }
        std::string addressValue(addressText);
        if (family == AF_INET6) {
            const auto *address = reinterpret_cast<const sockaddr_in6 *>(entry->ifa_addr);
            if (IN6_IS_ADDR_LINKLOCAL(&address->sin6_addr) && addressValue.find('%') == std::string::npos) {
                addressValue += "%";
                addressValue += entry->ifa_name;
            }
        }

        const uint32_t prefixLength = maskBytes == nullptr ? 0 : CountMaskBits(
            reinterpret_cast<const uint8_t *>(maskBytes), addressLength);
        napi_value row = nullptr;
        if (napi_create_object(env, &row) != napi_ok ||
            !SetNamedString(env, row, "address", addressValue) ||
            !SetNamedString(env, row, "interfaceName", entry->ifa_name) ||
            !SetNamedInt(env, row, "family", family == AF_INET ? 4 : 6) ||
            !SetNamedInt(env, row, "prefixLength", static_cast<int32_t>(prefixLength)) ||
            !SetNamedInt(env, row, "scopeId", static_cast<int32_t>(scopeId)) ||
            !SetNamedBool(env, row, "isLoopback", (entry->ifa_flags & IFF_LOOPBACK) != 0 || loopbackAddress) ||
            !SetNamedBool(env, row, "isUp", (entry->ifa_flags & IFF_UP) != 0) ||
            !SetNamedBool(env, row, "isRunning", (entry->ifa_flags & IFF_RUNNING) != 0)) {
            continue;
        }
        napi_set_element(env, result, index++, row);
    }

    freeifaddrs(interfaces);
    return result;
}

napi_value GetListenerSocketInfo(napi_env env, napi_callback_info info)
{
    size_t argc = 1;
    napi_value argv[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);

    int32_t fd = -1;
    if (argc != 1 || napi_get_value_int32(env, argv[0], &fd) != napi_ok || fd < 0) {
        napi_throw_type_error(env, nullptr, "A valid listening socket fd is required");
        return nullptr;
    }

    sockaddr_storage address{};
    socklen_t addressLength = sizeof(address);
    if (getsockname(fd, reinterpret_cast<sockaddr *>(&address), &addressLength) != 0) {
        const int error = errno;
        napi_throw_error(env, std::to_string(error).c_str(), "getsockname failed for listener");
        return nullptr;
    }

    int32_t family = 0;
    uint16_t port = 0;
    int32_t v6Only = -1;
    if (address.ss_family == AF_INET) {
        const auto *ipv4 = reinterpret_cast<const sockaddr_in *>(&address);
        family = 4;
        port = ntohs(ipv4->sin_port);
    } else if (address.ss_family == AF_INET6) {
        const auto *ipv6 = reinterpret_cast<const sockaddr_in6 *>(&address);
        family = 6;
        port = ntohs(ipv6->sin6_port);
        socklen_t optionLength = sizeof(v6Only);
        if (getsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &v6Only, &optionLength) != 0) {
            v6Only = -1;
        }
    } else {
        napi_throw_error(env, nullptr, "Listener socket has an unsupported address family");
        return nullptr;
    }

    napi_value result = nullptr;
    if (napi_create_object(env, &result) != napi_ok ||
        !SetNamedInt(env, result, "family", family) ||
        !SetNamedInt(env, result, "port", static_cast<int32_t>(port)) ||
        !SetNamedInt(env, result, "ipv6Only", v6Only)) {
        napi_throw_error(env, nullptr, "Could not create listener socket information");
        return nullptr;
    }
    return result;
}

napi_value Init(napi_env env, napi_value exports)
{
    napi_value getUsbSpeed;
    napi_create_function(env, "getUsbSpeed", NAPI_AUTO_LENGTH, GetUsbSpeed, nullptr, &getUsbSpeed);
    napi_set_named_property(env, exports, "getUsbSpeed", getUsbSpeed);
    napi_value getInterfaceAddresses;
    napi_create_function(env, "getInterfaceAddresses", NAPI_AUTO_LENGTH, GetInterfaceAddresses, nullptr,
        &getInterfaceAddresses);
    napi_set_named_property(env, exports, "getInterfaceAddresses", getInterfaceAddresses);
    napi_value getListenerSocketInfo;
    napi_create_function(env, "getListenerSocketInfo", NAPI_AUTO_LENGTH, GetListenerSocketInfo, nullptr,
        &getListenerSocketInfo);
    napi_set_named_property(env, exports, "getListenerSocketInfo", getListenerSocketInfo);
    return exports;
}

} // namespace

NAPI_MODULE(usbip_native, Init)
