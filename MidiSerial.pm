package MidiSerial;

use strict;
use warnings;
use Time::HiRes;

our $SHOW_MIDI_MSG = 1;
our $SEND_MIDI_MSG = 1;

# GPIO control base path
our $GPIO_BASE_PATH = "/sys/class/gpio";

# Base gpio for reset of the midi chip
our $BASE_CONTROL_PIN = 12;

# How long the reset pin should be held for (in seconds)
our $RESET_DURATION = 0.100;

# How long after reset is released before doing stuff (in seconds)
our $POST_RESET_ALLOWANCE = 0.100;

our $SERIAL_BAUD_RATE = 31250;
our $SERIAL_PARITY = "none";
our $SERIAL_DATA_BITS = 8;
our $SERIAL_STOP_BITS = 1;
our $SERIAL_HANDSHAKE = "none";

our $CMD_NOTE_OFF = 0;
our $CMD_NOTE_ON = 1;
our $CMD_AFTERTOUCH = 2;
our $CMD_CONTINUOUS_CONTROLLER = 3;
our $CMD_PATCH_CHANGE = 4;
our $CMD_CHANNEL_PRESSURE = 5;
our $CMD_PITCH_BEND = 6;
our $CMD_NON_MUSICAL = 7;

our $CTRL_BANK_SELECT_MSB = 0;
our $CTRL_BANK_SELECT_LSB = 32;
our $CTRL_MODULATION_WHEEL = 1;
our $CTRL_VOLUME = 7;
our $CTRL_PANORAMIC = 10;
our $CTRL_EXPRESSION = 11;
our $CTRL_SUSTAIN_PEDAL = 64;
our $CTRL_ALL_CONTROLLERS_OFF = 121;
our $CTRL_ALL_NOTES_OFF = 123;




# setup($device);
# reset();
# patch_change(0, 0);  # Grand piano I think?
# note_on(0, 60);  # C4
# note_off(0, 60);
# note_on(0, 58);   # A3
# all_notes_off(0);
# teardown();



my $po;

sub setup {
    my ($port_path,$preset,$no_hw_reset) = @_;
    die "ERROR: Need to specify value device path\n" if ! -c $port_path;
    die "ERROR: Port already configured\n" if defined $po;

    if(!$preset) {
	# Setup basic stuff with normal stty
	my $settings_string = "";

	$settings_string .= "cs${SERIAL_DATA_BITS} "; # Only works for 5, 6, 7, 8
	$settings_string .= "-crtscts -ixon -ixoff ";  # Ignore the handshake parameter and just turn it all off...
	$settings_string .= "-cstopb " if $SERIAL_STOP_BITS == 1;
	$settings_string .= "cstopb " if $SERIAL_STOP_BITS == 2;
	die "ERROR: Unsupported stop bits\n" if $SERIAL_STOP_BITS != 1 && $SERIAL_STOP_BITS != 2;
	$settings_string .= "-parenb " if $SERIAL_PARITY eq "none";
	$settings_string .= "parenb parodd " if $SERIAL_PARITY eq "odd";
	$settings_string .= "parenb -parodd " if $SERIAL_PARITY eq "even";
		
	system("stty -F $port_path $settings_string");
	# Setup baud rate (with my stty-plus program)
	system("/home/pi/stty-plus $port_path $SERIAL_BAUD_RATE");
    }
    
    open($po, ">$port_path") or die "ERROR: Open failed $!\n";

    if(!$no_hw_reset) {
	if (! -d "$GPIO_BASE_PATH/gpio${BASE_CONTROL_PIN}") {
	    system("echo $BASE_CONTROL_PIN > $GPIO_BASE_PATH/export");
	}
	system("echo high > $GPIO_BASE_PATH/gpio${BASE_CONTROL_PIN}/direction");

	system("echo 0 > $GPIO_BASE_PATH/gpio${BASE_CONTROL_PIN}/value");
	Time::HiRes::clock_nanosleep(Time::HiRes::CLOCK_MONOTONIC(), $RESET_DURATION*1e9);
	system("echo 1 > $GPIO_BASE_PATH/gpio${BASE_CONTROL_PIN}/value");
	Time::HiRes::clock_nanosleep(Time::HiRes::CLOCK_MONOTONIC(), $POST_RESET_ALLOWANCE*1e9);
    }

}

sub teardown {
    my ($reset_state) = @_;
    
    if(defined $po) {
	close($po) or die "ERROR: Close failed $!\n";
	undef $po;
    }

    if(defined $reset_state) {
	if($reset_state) {
	    # put it into reset and then go hi-z and unexport

	    system("echo 0 > $GPIO_BASE_PATH/gpio${BASE_CONTROL_PIN}/value");
	    
	    if (-d "$GPIO_BASE_PATH/gpio${BASE_CONTROL_PIN}") {
		system("echo $BASE_CONTROL_PIN > $GPIO_BASE_PATH/unexport");
	    }
	} else {
	    # just leave un-reset (no unexport)
	}
    }
}

sub volume {
    my ($channel, $volume) = @_;
    control($channel, $CTRL_VOLUME, $volume);
}

sub all_controllers_off {
    my ($channel) = @_;
    control($channel, $CTRL_ALL_CONTROLLERS_OFF, 0);
}

sub all_notes_off {
    my ($channel) = @_;
    control($channel, $CTRL_ALL_NOTES_OFF, 0);
}

sub reset {
    command($CMD_NON_MUSICAL, 0xF);
}

sub program_change {
    my ($channel, $instrument) = @_;
    command($CMD_PATCH_CHANGE, $channel, $instrument);
}

sub note_on {
    my ($channel, $key, $velocity) = @_;
    command($CMD_NOTE_ON, $channel, $key, $velocity // 64);
}

sub note_off {
    my ($channel, $key, $velocity) = @_;
    command($CMD_NOTE_OFF, $channel, $key, $velocity // 0);
}

sub aftertouch {
    my ($channel, $key, $touch) = @_;
    command($CMD_AFTERTOUCH, $channel, $key, $touch);
}

sub control {
    my ($channel, $value) = @_;
    command($CMD_CONTINUOUS_CONTROLLER, $channel, $value);
}

sub channel_pressure {
    my ($channel, $pressure) = @_;
    command($CMD_CHANNEL_PRESSURE, $channel, $pressure);
}

sub pitch_bend {
    my ($channel, $adjustment) = @_;
    command($CMD_PITCH_BEND, $channel, ($adjustment & 0x3F), (($adjustment >> 7) & 0x3F));
}

sub command {
    my ($status, $channel, @parm_bytes) = @_;

    die "ERROR: command() asked to send invalid status ($status)\n" if $status > 7 || $status < 0;
    die "ERROR: command() asked to use invalid channel ($channel)\n" if $channel > 15 || $status < 0;
    foreach(@parm_bytes) {
	die "ERROR: command() asked to send invalid parameter byte ($_)\n" if $_ > 127 || $_ < 0;
    }

    my $status_byte = 0x80 + ($status << 4) + $channel;

    if($SHOW_MIDI_MSG) {
	printf("command: Sending %02X ", $status_byte);
	printf("%02X", $_) foreach @parm_bytes;
	print("\n");
    }

    my $value = pack("C*", $status_byte, @parm_bytes);

    if($SEND_MIDI_MSG) {
	if(defined $po) {
	    syswrite($po,$value) or die "ERROR: command() write failed $!\n";
	} else {
	    die "ERROR: command() Port not configured.\n";
	}
    }
}


1;
