// Support for bit-banging commands to CS1237 ADC chips
//
// Copyright (C) 2026  The Klipper project
//
// This file may be distributed under the terms of the GNU GPLv3 license.

#include <stdint.h>
#include "autoconf.h" // CONFIG_MACH_AVR
#include "basecmd.h" // oid_alloc
#include "board/gpio.h" // gpio_out_write
#include "board/irq.h" // irq_poll
#include "board/misc.h" // timer_read_time
#include "command.h" // DECL_COMMAND
#include "sched.h" // sched_add_timer
#include "sensor_bulk.h" // sensor_bulk_report
#include "trigger_analog.h" // trigger_analog_update

struct cs1237_adc {
    struct timer timer;
    uint8_t config;
    uint8_t flags;
    uint8_t sensor_error;
    uint32_t rest_ticks;
    uint32_t last_error;
    int32_t last_sample;
    struct gpio_in dout_in; // bidirectional data-ready / data pin
    struct gpio_out dout_out;
    struct gpio_out sclk;
    struct sensor_bulk sb;
    struct trigger_analog *ta;
};

enum {
    CS_PENDING = 1 << 0, CS_OVERFLOW = 1 << 1,
};

// Internal sample error values reported over bulk transport
#define BYTES_PER_SAMPLE 4
#define SAMPLE_ERROR_TIMEOUT (1L << 31)
#define SAMPLE_ERROR_READ_TOO_LONG (1L << 30)
#define SAMPLE_ERROR_CONFIG (1L << 29)

// Sensor-specific errors passed to trigger_analog_note_error()
enum {
    CSE_CONFIG_TIMEOUT = 1,
    CSE_CONFIG_MISMATCH = 2,
    CSE_READ_TIMEOUT = 3,
    CSE_OVERFLOW = 4,
};

// CS1237 command words (7-bit)
#define CMD_WRITE_CONFIG 0x65
#define CMD_READ_CONFIG 0x56

static struct task_wake wake_cs1237;


/****************************************************************
 * Low-level bit-banging
 ****************************************************************/

#define MIN_PULSE_TIME nsecs_to_ticks(500) // datasheet min pulse ~455ns

static uint32_t
nsecs_to_ticks(uint32_t ns)
{
    return timer_from_us(ns * 1000) / 1000000;
}

// Pause for a minimum pulse time with irq disabled
static void
cs1237_delay_noirq(void)
{
    if (CONFIG_MACH_AVR) {
        // Optimize avr, as calculating time takes longer than needed delay
        asm("nop\n    nop");
        return;
    }
    uint32_t end = timer_read_time() + MIN_PULSE_TIME;
    while (timer_is_before(timer_read_time(), end))
        ;
}

// Pause for a minimum pulse time
static void
cs1237_delay(void)
{
    if (CONFIG_MACH_AVR)
        return;
    uint32_t end = timer_read_time() + MIN_PULSE_TIME;
    while (timer_is_before(timer_read_time(), end))
        irq_poll();
}

static uint8_t
cs1237_is_data_ready(struct cs1237_adc *cs1237)
{
    return !gpio_in_read(cs1237->dout_in);
}

static void
cs1237_clock_pulse(struct cs1237_adc *cs1237)
{
    irq_disable();
    gpio_out_toggle_noirq(cs1237->sclk);
    cs1237_delay_noirq();
    gpio_out_toggle_noirq(cs1237->sclk);
    irq_enable();
    cs1237_delay();
}

static uint8_t
cs1237_read_bit(struct cs1237_adc *cs1237)
{
    irq_disable();
    gpio_out_toggle_noirq(cs1237->sclk);
    cs1237_delay_noirq();
    uint8_t bit = gpio_in_read(cs1237->dout_in);
    gpio_out_toggle_noirq(cs1237->sclk);
    irq_enable();
    cs1237_delay();
    return bit;
}

static void
cs1237_write_bit(struct cs1237_adc *cs1237, uint8_t bit)
{
    gpio_out_write(cs1237->dout_out, !!bit);
    cs1237_clock_pulse(cs1237);
}

// Read one CS1237 ADC frame and move to next conversion.
// Returns a 24-bit value (in the low bits of the return value).
static uint32_t
cs1237_read_frame(struct cs1237_adc *cs1237, uint8_t *status)
{
    uint32_t counts = 0;
    uint8_t i;
    for (i = 0; i < 24; i++)
        counts = (counts << 1) | cs1237_read_bit(cs1237);
    uint8_t update1 = cs1237_read_bit(cs1237);
    uint8_t update2 = cs1237_read_bit(cs1237);
    // 27th pulse forces DOUT high until the next conversion is ready
    cs1237_clock_pulse(cs1237);
    if (status)
        *status = update1 | (update2 << 1);
    return counts;
}

static void
cs1237_send_command7(struct cs1237_adc *cs1237, uint8_t cmd)
{
    int_fast8_t i;
    for (i = 6; i >= 0; i--)
        cs1237_write_bit(cs1237, (cmd >> i) & 0x01);
}

static int
cs1237_wait_data_ready(struct cs1237_adc *cs1237, uint32_t timeout_ticks)
{
    uint32_t end = timer_read_time() + timeout_ticks;
    while (timer_is_before(timer_read_time(), end)) {
        if (cs1237_is_data_ready(cs1237))
            return 0;
        irq_poll();
    }
    return -1;
}

static int
cs1237_write_config(struct cs1237_adc *cs1237, uint8_t config)
{
    if (cs1237_wait_data_ready(cs1237, timer_from_us(500000)))
        return CSE_CONFIG_TIMEOUT;
    // Enter config sequence by reading the current conversion frame.
    // This consumes clocks 1..27 (24 data + 2 status + 1 latch-high).
    cs1237_read_frame(cs1237, NULL);
    // Datasheet config sequence uses 46 SCLK pulses total:
    // 28..29 direction-switch clocks, 30..36 command bits,
    // 37 direction-select clock, 38..45 payload bits, 46 finalize.
    gpio_out_reset(cs1237->dout_out, 1);
    // Clocks 28..29
    cs1237_clock_pulse(cs1237);
    cs1237_clock_pulse(cs1237);
    // Clocks 30..36: 7-bit write command
    cs1237_send_command7(cs1237, CMD_WRITE_CONFIG);
    // Clock 37: direction-select clock (write path keeps MCU driving)
    cs1237_clock_pulse(cs1237);
    // Clocks 38..45: 8-bit payload
    int_fast8_t i;
    for (i = 7; i >= 0; i--)
        cs1237_write_bit(cs1237, (config >> i) & 0x01);
    // Clock 46 finalizes the transaction
    cs1237_clock_pulse(cs1237);
    // Release bus back to input mode for normal conversion reads
    gpio_in_reset(cs1237->dout_in, 1);
    return 0;
}

static int
cs1237_read_config(struct cs1237_adc *cs1237, uint8_t *config)
{
    if (cs1237_wait_data_ready(cs1237, timer_from_us(500000)))
        return CSE_CONFIG_TIMEOUT;
    // Clocks 1..27
    cs1237_read_frame(cs1237, NULL);
    // Clocks 28..29: direction-switch clocks
    gpio_out_reset(cs1237->dout_out, 1);
    cs1237_clock_pulse(cs1237);
    cs1237_clock_pulse(cs1237);
    // Clocks 30..36: 7-bit read command
    cs1237_send_command7(cs1237, CMD_READ_CONFIG);
    // Clock 37: switch bus direction for readback
    gpio_in_reset(cs1237->dout_in, 1);
    cs1237_clock_pulse(cs1237);
    // Clocks 38..45: 8-bit register payload
    uint8_t readback = 0;
    uint8_t i;
    for (i = 0; i < 8; i++)
        readback = (readback << 1) | cs1237_read_bit(cs1237);
    // Clock 46 finalize, with MCU driving high per datasheet
    gpio_out_reset(cs1237->dout_out, 1);
    cs1237_clock_pulse(cs1237);
    gpio_in_reset(cs1237->dout_in, 1);
    *config = readback;
    return 0;
}

static int
cs1237_configure_chip(struct cs1237_adc *cs1237)
{
    // Datasheet power-down exit: keep SCLK low for at least 10us
    gpio_out_write(cs1237->sclk, 0);
    uint32_t wake_end = timer_read_time() + timer_from_us(20);
    while (timer_is_before(timer_read_time(), wake_end))
        irq_poll();
    gpio_in_reset(cs1237->dout_in, 1);
    int ret = cs1237_write_config(cs1237, cs1237->config);
    if (ret)
        return ret;
    uint8_t readback = 0;
    ret = cs1237_read_config(cs1237, &readback);
    if (ret)
        return ret;
    if ((readback & 0x7f) != (cs1237->config & 0x7f))
        return CSE_CONFIG_MISMATCH;
    return 0;
}


/****************************************************************
 * CS1237 Sensor Support
 ****************************************************************/

// Event handler that wakes wake_cs1237() periodically
static uint_fast8_t
cs1237_event(struct timer *timer)
{
    struct cs1237_adc *cs1237 = container_of(timer, struct cs1237_adc, timer);
    uint32_t rest_ticks = cs1237->rest_ticks;
    uint8_t flags = cs1237->flags;
    if (flags & CS_PENDING) {
        cs1237->sb.possible_overflows++;
        cs1237->flags = CS_PENDING | CS_OVERFLOW;
        rest_ticks *= 4;
    } else if (cs1237_is_data_ready(cs1237)) {
        // New sample pending
        cs1237->flags = CS_PENDING;
        sched_wake_task(&wake_cs1237);
        rest_ticks *= 8;
    }
    cs1237->timer.waketime += rest_ticks;
    return SF_RESCHEDULE;
}

static void
add_sample(struct cs1237_adc *cs1237, uint8_t oid, uint32_t counts,
           uint8_t force_flush)
{
    cs1237->sb.data[cs1237->sb.data_count] = counts;
    cs1237->sb.data[cs1237->sb.data_count + 1] = counts >> 8;
    cs1237->sb.data[cs1237->sb.data_count + 2] = counts >> 16;
    cs1237->sb.data[cs1237->sb.data_count + 3] = counts >> 24;
    cs1237->sb.data_count += BYTES_PER_SAMPLE;
    if (cs1237->sb.data_count + BYTES_PER_SAMPLE > ARRAY_SIZE(cs1237->sb.data)
        || force_flush)
        sensor_bulk_report(&cs1237->sb, oid);
}

// CS1237 ADC query
static void
cs1237_read_adc(struct cs1237_adc *cs1237, uint8_t oid)
{
    // Clear pending flag (and note if an overflow occurred)
    irq_disable();
    uint8_t flags = cs1237->flags;
    cs1237->flags = 0;
    irq_enable();

    uint32_t counts = 0;
    if (flags & CS_OVERFLOW) {
        cs1237->last_error = SAMPLE_ERROR_READ_TOO_LONG;
        cs1237->sensor_error = CSE_OVERFLOW;
    } else if (cs1237->last_error == 0) {
        // Read from sensor (data ready should already be low)
        if (!cs1237_is_data_ready(cs1237)) {
            cs1237->last_error = SAMPLE_ERROR_TIMEOUT;
            cs1237->sensor_error = CSE_READ_TIMEOUT;
        } else {
            uint8_t status_bits = 0;
            counts = cs1237_read_frame(cs1237, &status_bits);
            (void)status_bits;
            // Extend 24-bit 2's complement to 32 bits
            if (counts & 0x800000)
                counts |= 0xFF000000;
        }
    }

    if (cs1237->last_error != 0) {
        counts = cs1237->last_error;
        trigger_analog_note_error(cs1237->ta, cs1237->sensor_error);
    } else {
        cs1237->last_sample = (int32_t)counts;
        trigger_analog_update(cs1237->ta, counts);
    }
    add_sample(cs1237, oid, counts, 0);
}

// Create a cs1237 sensor
void
command_config_cs1237(uint32_t *args)
{
    struct cs1237_adc *cs1237 = oid_alloc(args[0]
                , command_config_cs1237, sizeof(*cs1237));
    cs1237->timer.func = cs1237_event;
    cs1237->config = args[1] & 0x7f;
    cs1237->dout_out = gpio_out_setup(args[2], 1);
    cs1237->dout_in = gpio_in_setup(args[2], 1);
    cs1237->sclk = gpio_out_setup(args[3], 1); // high -> power down
    cs1237->last_sample = 0;
}
DECL_COMMAND(command_config_cs1237, "config_cs1237 oid=%c config=%c"
             " dout_pin=%u sclk_pin=%u");

void
cs1237_attach_trigger_analog(uint32_t *args)
{
    struct cs1237_adc *cs1237 = oid_lookup(args[0], command_config_cs1237);
    cs1237->ta = trigger_analog_oid_lookup(args[1]);
}
#if CONFIG_WANT_TRIGGER_ANALOG
DECL_COMMAND(cs1237_attach_trigger_analog, "cs1237_attach_trigger_analog"
             " oid=%c trigger_analog_oid=%c");
#endif

// start/stop capturing ADC data
void
command_query_cs1237(uint32_t *args)
{
    struct cs1237_adc *cs1237 = oid_lookup(args[0], command_config_cs1237);
    sched_del_timer(&cs1237->timer);
    cs1237->flags = 0;
    cs1237->last_error = 0;
    cs1237->sensor_error = 0;
    cs1237->rest_ticks = args[1];
    if (!cs1237->rest_ticks) {
        // End measurements - SCLK high for >100us enters power down
        gpio_out_write(cs1237->sclk, 1);
        gpio_in_reset(cs1237->dout_in, 1);
        return;
    }
    // Start new measurements
    sensor_bulk_reset(&cs1237->sb);
    int ret = cs1237_configure_chip(cs1237);
    if (ret) {
        cs1237->last_error = SAMPLE_ERROR_CONFIG;
        cs1237->sensor_error = ret;
        trigger_analog_note_error(cs1237->ta, cs1237->sensor_error);
    }
    irq_disable();
    cs1237->timer.waketime = timer_read_time() + cs1237->rest_ticks;
    sched_add_timer(&cs1237->timer);
    irq_enable();
}
DECL_COMMAND(command_query_cs1237, "query_cs1237 oid=%c rest_ticks=%u");

void
command_query_cs1237_status(const uint32_t *args)
{
    uint8_t oid = args[0];
    struct cs1237_adc *cs1237 = oid_lookup(oid, command_config_cs1237);
    irq_disable();
    const uint32_t start_t = timer_read_time();
    uint8_t is_data_ready = cs1237_is_data_ready(cs1237);
    irq_enable();
    uint8_t pending_bytes = is_data_ready ? BYTES_PER_SAMPLE : 0;
    sensor_bulk_status(&cs1237->sb, oid, start_t, 0, pending_bytes);
}
DECL_COMMAND(command_query_cs1237_status, "query_cs1237_status oid=%c");

// Background task that performs measurements
void
cs1237_capture_task(void)
{
    if (!sched_check_wake(&wake_cs1237))
        return;
    uint8_t oid;
    struct cs1237_adc *cs1237;
    foreach_oid(oid, cs1237, command_config_cs1237) {
        if (cs1237->flags)
            cs1237_read_adc(cs1237, oid);
    }
}
DECL_TASK(cs1237_capture_task);
