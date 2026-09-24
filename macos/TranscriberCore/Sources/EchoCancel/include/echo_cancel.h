#ifndef ECHO_CANCEL_H
#define ECHO_CANCEL_H

#include <stdint.h>

typedef struct EchoCancelState EchoCancelState;

EchoCancelState *echo_cancel_create(int length, float step_size);
void echo_cancel_destroy(EchoCancelState *state);
void echo_cancel_reset(EchoCancelState *state);
void echo_cancel_process(
    EchoCancelState *state,
    const int16_t *microphone,
    const int16_t *reference,
    int16_t *output,
    int count
);

#endif
