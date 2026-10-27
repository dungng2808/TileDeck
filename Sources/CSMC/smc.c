#include "smc.h"
#include <string.h>

// Struct layout and selectors used by the AppleSMC kernel user client.
enum { kSMCUserClientSelector = 2 };
enum { kSMCReadKey = 5, kSMCWriteKey = 6, kSMCGetKeyFromIndex = 8, kSMCGetKeyInfo = 9 };

typedef struct {
    uint8_t major, minor, build, reserved;
    uint16_t release;
} SMCVersion;

typedef struct {
    uint16_t version, length;
    uint32_t cpuPLimit, gpuPLimit, memPLimit;
} SMCPLimitData;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
} SMCKeyInfoData;

typedef struct {
    uint32_t key;
    SMCVersion vers;
    SMCPLimitData pLimitData;
    SMCKeyInfoData keyInfo;
    uint8_t result, status, data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData;

static uint32_t fourcc(const char *key) {
    return ((uint32_t)key[0] << 24) | ((uint32_t)key[1] << 16) | ((uint32_t)key[2] << 8) | (uint32_t)key[3];
}

static kern_return_t call(io_connect_t connection, SMCKeyData *input, SMCKeyData *output) {
    size_t outputSize = sizeof(SMCKeyData);
    kern_return_t result = IOConnectCallStructMethod(connection, kSMCUserClientSelector, input, sizeof(SMCKeyData), output, &outputSize);
    if (result != KERN_SUCCESS) return result;
    return output->result == 0 ? KERN_SUCCESS : kIOReturnError;
}

static kern_return_t key_info(io_connect_t connection, uint32_t key, SMCKeyInfoData *info) {
    SMCKeyData input = {0}, output = {0};
    input.key = key;
    input.data8 = kSMCGetKeyInfo;
    kern_return_t result = call(connection, &input, &output);
    if (result == KERN_SUCCESS) *info = output.keyInfo;
    return result;
}

kern_return_t smc_open(io_connect_t *connection) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return kIOReturnNotFound;
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, connection);
    IOObjectRelease(service);
    return result;
}

void smc_close(io_connect_t connection) {
    IOServiceClose(connection);
}

kern_return_t smc_read(io_connect_t connection, const char *key, uint8_t bytes[32], uint32_t *size) {
    SMCKeyData input = {0}, output = {0};
    input.key = fourcc(key);
    kern_return_t result = key_info(connection, input.key, &input.keyInfo);
    if (result != KERN_SUCCESS) return result;

    input.data8 = kSMCReadKey;
    result = call(connection, &input, &output);
    if (result != KERN_SUCCESS) return result;

    *size = input.keyInfo.dataSize > 32 ? 32 : input.keyInfo.dataSize;
    memcpy(bytes, output.bytes, *size);
    return KERN_SUCCESS;
}

kern_return_t smc_write(io_connect_t connection, const char *key, const uint8_t *bytes, uint32_t size) {
    SMCKeyData input = {0}, output = {0};
    input.key = fourcc(key);
    kern_return_t result = key_info(connection, input.key, &input.keyInfo);
    if (result != KERN_SUCCESS) return result;
    if (input.keyInfo.dataSize != size || size > 32) return kIOReturnBadArgument;

    input.data8 = kSMCWriteKey;
    memcpy(input.bytes, bytes, size);
    return call(connection, &input, &output);
}

uint32_t smc_key_count(io_connect_t connection) {
    uint8_t bytes[32];
    uint32_t size = 0;
    if (smc_read(connection, "#KEY", bytes, &size) != KERN_SUCCESS || size < 4) return 0;
    return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) | ((uint32_t)bytes[2] << 8) | (uint32_t)bytes[3];
}

kern_return_t smc_key_at(io_connect_t connection, uint32_t index, char key[5]) {
    SMCKeyData input = {0}, output = {0};
    input.data8 = kSMCGetKeyFromIndex;
    input.data32 = index;
    kern_return_t result = call(connection, &input, &output);
    if (result != KERN_SUCCESS) return result;
    key[0] = (char)(output.key >> 24);
    key[1] = (char)(output.key >> 16);
    key[2] = (char)(output.key >> 8);
    key[3] = (char)output.key;
    key[4] = 0;
    return KERN_SUCCESS;
}
