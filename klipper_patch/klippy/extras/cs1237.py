# CS1237 Support
#
# Copyright (C) 2026  The Klipper project
#
# This file may be distributed under the terms of the GNU GPLv3 license.
import logging
from . import bulk_sensor

#
# Constants
#
UPDATE_INTERVAL = 0.10
SAMPLE_ERROR_TIMEOUT = -0x80000000
SAMPLE_ERROR_LONG_READ = 0x40000000
SAMPLE_ERROR_CONFIG = 0x20000000

# Sensor-specific trigger_analog errors (from sensor_cs1237.c)
CS1237_ERR_CONFIG_TIMEOUT = 1
CS1237_ERR_CONFIG_MISMATCH = 2
CS1237_ERR_READ_TIMEOUT = 3
CS1237_ERR_OVERFLOW = 4

# Config register bit fields
SAMPLE_RATE_OPTIONS = {10: 0, 40: 1, 640: 2, 1280: 3}
GAIN_OPTIONS = {'1': 0, '2': 1, '64': 2, '128': 3}
CHANNEL_OPTIONS = {'A': 0, 'temperature': 2, 'short': 3}


class CS1237:
    def __init__(self, config, calibration=None):
        self.printer = printer = config.get_printer()
        self.name = config.get_name().split()[-1]
        self.last_error_count = 0
        self.consecutive_fails = 0
        self.query_cs1237_cmd = None
        # Chip options
        dout_pin_name = config.get('dout_pin')
        sclk_pin_name = config.get('sclk_pin')
        ppins = printer.lookup_object('pins')
        dout_ppin = ppins.lookup_pin(dout_pin_name)
        sclk_ppin = ppins.lookup_pin(sclk_pin_name)
        self.mcu = mcu = dout_ppin['chip']
        self.oid = mcu.create_oid()
        if sclk_ppin['chip'] is not mcu:
            raise config.error("%s config error: All pins must be "
                               "connected to the same MCU" % (self.name,))
        self.dout_pin = dout_ppin['pin']
        self.sclk_pin = sclk_ppin['pin']
        # Config register setup
        self.sps = config.getchoice('sample_rate',
                                    {k: k for k in SAMPLE_RATE_OPTIONS},
                                    default=1280)
        speed_sel = SAMPLE_RATE_OPTIONS[self.sps]
        gain_bits = config.getchoice('gain', GAIN_OPTIONS, default='128')
        chan_sel = config.getchoice('channel', CHANNEL_OPTIONS, default='A')
        refout_off = int(config.getboolean('refout_off', default=False))
        config_reg = (refout_off << 6) | (speed_sel << 4)
        config_reg |= (gain_bits << 2) | chan_sel
        # Bulk Sensor Setup
        chip_smooth = self.sps * UPDATE_INTERVAL * 2
        self.ffreader = bulk_sensor.FixedFreqReader(mcu, chip_smooth, "<i")
        self.batch_bulk = bulk_sensor.BatchBulkHelper(
            self.printer, self._process_batch, self._start_measurements,
            self._finish_measurements, UPDATE_INTERVAL)
        # Command configuration
        mcu.add_config_cmd(
            "config_cs1237 oid=%d config=%d dout_pin=%s sclk_pin=%s"
            % (self.oid, config_reg, self.dout_pin, self.sclk_pin))
        mcu.add_config_cmd("query_cs1237 oid=%d rest_ticks=0"
                           % (self.oid,), on_restart=True)
        mcu.register_config_callback(self._build_config)

    def setup_trigger_analog(self, trigger_analog_oid):
        self.mcu.add_config_cmd(
            "cs1237_attach_trigger_analog oid=%d trigger_analog_oid=%d"
            % (self.oid, trigger_analog_oid), is_init=True)

    def _build_config(self):
        cmd_queue = self.mcu.alloc_command_queue()
        self.query_cs1237_cmd = self.mcu.lookup_command(
            "query_cs1237 oid=%c rest_ticks=%u", cq=cmd_queue)
        self.ffreader.setup_query_command("query_cs1237_status oid=%c",
                                          oid=self.oid, cq=cmd_queue)

    def get_mcu(self):
        return self.mcu

    def get_samples_per_second(self):
        return self.sps

    def get_status(self, eventtime):
        return {
            'errors': self.last_error_count,
            'overflows': self.ffreader.get_last_overflows(),
            'sample_rate': self.get_samples_per_second(),
        }

    def lookup_sensor_error(self, error_code):
        if error_code == CS1237_ERR_CONFIG_TIMEOUT:
            return "CS1237 config timeout"
        if error_code == CS1237_ERR_CONFIG_MISMATCH:
            return "CS1237 config mismatch"
        if error_code == CS1237_ERR_READ_TIMEOUT:
            return "CS1237 read timeout"
        if error_code == CS1237_ERR_OVERFLOW:
            return "CS1237 sample overflow"
        return "Unknown cs1237 error %d" % (error_code,)

    # returns a tuple of the minimum and maximum value of the sensor, used to
    # detect if a data value is saturated
    def get_range(self):
        return -0x800000, 0x7FFFFF

    # add_client interface, direct pass through to bulk_sensor API
    def add_client(self, callback):
        self.batch_bulk.add_client(callback)

    # Measurement decoding
    def _convert_samples(self, samples):
        adc_factor = 1. / (1 << 23)
        count = 0
        for ptime, val in samples:
            if val in (SAMPLE_ERROR_TIMEOUT, SAMPLE_ERROR_LONG_READ,
                       SAMPLE_ERROR_CONFIG):
                self.last_error_count += 1
                break  # additional errors are duplicates
            samples[count] = (round(ptime, 6), val, round(val * adc_factor, 9))
            count += 1
        del samples[count:]

    # Start, stop, and process message batches
    def _start_measurements(self):
        self.consecutive_fails = 0
        self.last_error_count = 0
        # Start bulk reading
        rest_ticks = self.mcu.seconds_to_clock(1. / (10. * self.sps))
        self.query_cs1237_cmd.send([self.oid, rest_ticks])
        logging.info("CS1237 starting '%s' measurements", self.name)
        # Initialize clock tracking
        self.ffreader.note_start()

    def _finish_measurements(self):
        # don't use serial connection after shutdown
        if self.printer.is_shutdown():
            return
        # Halt bulk reading
        self.query_cs1237_cmd.send_wait_ack([self.oid, 0])
        self.ffreader.note_end()
        logging.info("CS1237 finished '%s' measurements", self.name)

    def _process_batch(self, eventtime):
        prev_overflows = self.ffreader.get_last_overflows()
        prev_error_count = self.last_error_count
        samples = self.ffreader.pull_samples()
        self._convert_samples(samples)
        overflows = self.ffreader.get_last_overflows() - prev_overflows
        errors = self.last_error_count - prev_error_count
        if errors > 0:
            logging.error("%s: Forced sensor restart due to error", self.name)
            self._finish_measurements()
            self._start_measurements()
        elif overflows > 0:
            self.consecutive_fails += 1
            if self.consecutive_fails > 4:
                logging.error("%s: Forced sensor restart due to overflows",
                              self.name)
                self._finish_measurements()
                self._start_measurements()
        else:
            self.consecutive_fails = 0
        return {'data': samples, 'errors': self.last_error_count,
                'overflows': self.ffreader.get_last_overflows()}


CS1237_SENSOR_TYPE = {"cs1237": CS1237}
