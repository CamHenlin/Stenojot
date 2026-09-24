#include "echo_cancel.h"

#include <stdlib.h>
#include <string.h>

struct EchoCancelState {
    int length;
    int cursor;
    float step_size;
    float near_power;
    float far_power;
    float *weights;
    float *delay;
};

EchoCancelState *echo_cancel_create(int length, float step_size) {
    if (length <= 0) {
        return NULL;
    }
    EchoCancelState *state = calloc(1, sizeof(EchoCancelState));
    if (state == NULL) {
        return NULL;
    }
    state->weights = calloc((size_t)length, sizeof(float));
    state->delay = calloc((size_t)length, sizeof(float));
    if (state->weights == NULL || state->delay == NULL) {
        echo_cancel_destroy(state);
        return NULL;
    }
    state->length = length;
    state->step_size = step_size;
    return state;
}

void echo_cancel_destroy(EchoCancelState *state) {
    if (state == NULL) {
        return;
    }
    free(state->weights);
    free(state->delay);
    free(state);
}

void echo_cancel_reset(EchoCancelState *state) {
    if (state == NULL) {
        return;
    }
    memset(state->weights, 0, (size_t)state->length * sizeof(float));
    memset(state->delay, 0, (size_t)state->length * sizeof(float));
    state->cursor = 0;
    state->near_power = 0;
    state->far_power = 0;
}

void echo_cancel_process(
    EchoCancelState *state,
    const int16_t *microphone,
    const int16_t *reference,
    int16_t *output,
    int count
) {
    if (state == NULL || microphone == NULL || reference == NULL || output == NULL || count <= 0) {
        return;
    }

    const int length = state->length;
    float *weights = state->weights;
    float *delay = state->delay;
    int cursor = state->cursor;
    float near_power = state->near_power;
    float far_power = state->far_power;
    const float step = state->step_size;

    for (int i = 0; i < count; i++) {
        const float mic = (float)microphone[i] / 32768.0f;
        const float ref = (float)reference[i] / 32768.0f;

        cursor++;
        if (cursor >= length) {
            cursor = 0;
        }
        delay[cursor] = ref;

        float echo = 0;
        float power = 0;
        int pos = cursor;
        for (int tap = 0; tap < length; tap++) {
            const float sample = delay[pos];
            echo += weights[tap] * sample;
            power += sample * sample;
            pos--;
            if (pos < 0) {
                pos = length - 1;
            }
        }

        float error = mic - echo;
        near_power = 0.95f * near_power + 0.05f * mic * mic;
        far_power = 0.95f * far_power + 0.05f * ref * ref;
        const int doubletalk = near_power > 1e-4f && near_power > far_power * 4.0f;
        if (power > 1e-6f && !doubletalk) {
            const float gain = step * error / (power + 1e-4f);
            pos = cursor;
            for (int tap = 0; tap < length; tap++) {
                weights[tap] += gain * delay[pos];
                pos--;
                if (pos < 0) {
                    pos = length - 1;
                }
            }
        }

        if (!(error > -1.5f && error < 1.5f)) {
            error = mic > 1.0f ? 1.0f : (mic < -1.0f ? -1.0f : mic);
        } else if (error > 1.0f) {
            error = 1.0f;
        } else if (error < -1.0f) {
            error = -1.0f;
        }

        float scaled = error * 32768.0f;
        if (scaled > 32767.0f) {
            scaled = 32767.0f;
        } else if (scaled < -32768.0f) {
            scaled = -32768.0f;
        }
        output[i] = (int16_t)scaled;
    }

    state->cursor = cursor;
    state->near_power = near_power;
    state->far_power = far_power;
}
