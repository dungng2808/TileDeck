#ifndef TILEDECK_SMC_H
#define TILEDECK_SMC_H

#include <IOKit/IOKitLib.h>
#include <stdint.h>

/// Minimal AppleSMC client. Reading works as any user; writing needs root.
kern_return_t smc_open(io_connect_t *connection);
void smc_close(io_connect_t connection);

/// `key` is a 4-character SMC key such as "CHTE". On success `size` holds the
/// value's byte count (at most 32) and `bytes` its raw big-endian contents.
kern_return_t smc_read(io_connect_t connection, const char *key, uint8_t bytes[32], uint32_t *size);
kern_return_t smc_write(io_connect_t connection, const char *key, const uint8_t *bytes, uint32_t size);

/// Number of keys the SMC exposes, and the key at a given index (as 4 chars plus a terminating NUL).
uint32_t smc_key_count(io_connect_t connection);
kern_return_t smc_key_at(io_connect_t connection, uint32_t index, char key[5]);

#endif
