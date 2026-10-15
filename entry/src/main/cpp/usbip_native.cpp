#include <cerrno>
#include <cstdint>
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

napi_value Init(napi_env env, napi_value exports)
{
    napi_value getUsbSpeed;
    napi_create_function(env, "getUsbSpeed", NAPI_AUTO_LENGTH, GetUsbSpeed, nullptr, &getUsbSpeed);
    napi_set_named_property(env, exports, "getUsbSpeed", getUsbSpeed);
    return exports;
}

} // namespace

NAPI_MODULE(usbip_native, Init)
