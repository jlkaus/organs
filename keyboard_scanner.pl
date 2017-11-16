#!/usr/bin/perl

use strict;
use warnings;
use Time::HiRes;
use MidiSerial;

# whether to show the events as they happen
our $SHOW_EVENTS = undef;
# whether to show setup/teardown actions
our $SHOW_SETUP = undef;
# whether to show final set of keys unactuated
our $SHOW_FINAL = undef;
# whether to show chord achieved
our $SHOW_CHORDS = undef;
# whether to show final timings achieved
our $SHOW_TIMES = undef;
# whether to show MIDI messages
our $SHOW_MIDI = undef;
# whether to actually send midi messages
our $ENABLE_MIDI = undef;

# Scan period (attempted) in seconds
our $SCAN_PERIOD = 0.02;
# Max time (in seconds) to hard spin for (rather than yield)
our $SPIN_MAX = 0.01;
# Transposition (positive or negative)
our $TRANSPOSE = 0;

# Which serial port to use for MIDI output
our $MIDI_SERIAL_PORT = undef;

# Which MIDI instruments to use
our @MIDI_INSTRUMENTS = ();

# MIDI velocity if key value is 1
our $MIDI_QUIET = 60;

# MIDI velocity if key value is 3
our $MIDI_LOUD = 96;

while($_ = shift @ARGV) {
    if($_ eq "--show-events") {
	$SHOW_EVENTS = 1;
    } elsif($_ eq "--show-setup") {
	$SHOW_SETUP = 1;
    } elsif($_ eq "--show-final") {
	$SHOW_FINAL = 1;
    } elsif($_ eq "--show-chords") {
	$SHOW_CHORDS = 1;
    } elsif($_ eq "--show-times") {
	$SHOW_TIMES = 1;
    } elsif($_ eq "--show-midi") {
	$SHOW_MIDI = 1;
    } elsif($_ eq "--enable-midi") {
	$ENABLE_MIDI = 1;
	$MIDI_SERIAL_PORT = shift;
    } elsif($_ eq "--scan-period") {
	$SCAN_PERIOD = shift;
    } elsif($_ eq "--spin-max") {
	$SPIN_MAX = shift;
    } elsif($_ eq "--transpose") {
	$TRANSPOSE = shift;
    } elsif($_ eq "--instrument") {
	push @MIDI_INSTRUMENTS, (split /[\s,]+/, shift);
    } elsif($_ eq "--loud") {
	$MIDI_LOUD = shift;
    } elsif($_ eq "--quiet") {
	$MIDI_QUIET = shift;
    }
}

$MidiSerial::SHOW_MIDI_MSG = $SHOW_MIDI;
$MidiSerial::SEND_MIDI_MSG = $ENABLE_MIDI;

# Default to just piano, if no instruments specified
if(scalar @MIDI_INSTRUMENTS == 0) {
    push @MIDI_INSTRUMENTS, 0;
}

# Key classes
our @key_classes = ("C","C#","D","D#","E","F","F#","G","G#","A","A#","B");

# GPIO control base path
our $GPIO_BASE_PATH = "/sys/class/gpio";

# Base gpio for 9-pin output port to control region
our $BASE_CONTROL_PIN = 2;
our $REGION_COUNT = 9;

# Base gpio for 12-pin input port for sense region
# First 6 and latter 6 pins are duplicate buttons, perhaps
# for some sort of velocity control?
our $BASE_KEYSENSE_PIN = 16;
our $KEYS_PER_REGION = 6;
our $DUPS_PER_KEY = 2;

# Base MIDI key number of first key in first region
our $MIDI_BASE = 55 + $TRANSPOSE;

sub trace {
    my ($level, $msg) = @_;

    if(($level eq "SETUP" && $SHOW_SETUP) ||
       ($level eq "EVENT" && $SHOW_EVENTS) ||
       ($level eq "FINAL" && $SHOW_FINAL) ||
       ($level eq "CHORD" && $SHOW_CHORDS) ||
       ($level eq "TIMES" && $SHOW_TIMES)) {
	print STDERR "$level: $msg\n";
    }
}

my $iterations = 0;
my $scan_time = 0;
my $true_start = 0;
my %max_key_state = ();
my $num_midi_channels = 0;
my %key_state = ();
my %cur_keys = ();
my $cur_chord = "";

sub termination {
    my $term_time = Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC());
    print STDERR "\n";
    trace("SETUP","Terminating due to SIGINT.");
    trace("TIMES","Completed $iterations scans, averaging ".($scan_time/$iterations)." seconds per scan.");
    trace("TIMES","Achieved average period of ".(($term_time - $true_start)/$iterations)." seconds.");

    my $expected = 0;
    for(my $k = 0; $k < $DUPS_PER_KEY; ++$k) {
	$expected += (1 << $k);
    }
    
    for(my $i = $MIDI_BASE; $i < $MIDI_BASE + $REGION_COUNT * $KEYS_PER_REGION; ++$i) {
	if($max_key_state{$i} != $expected) {
	    my $keyname = calcKey($i);
	    trace("FINAL","Key $i ($keyname) only got $max_key_state{$i}");
	}
    }

    # Teardown (unexport)
    for(my $i = $BASE_CONTROL_PIN; $i < $BASE_CONTROL_PIN + $REGION_COUNT; ++$i) {
	if (-d "$GPIO_BASE_PATH/gpio$i") {
	    trace("SETUP","Unexporting pin $i");
	    system("echo $i > $GPIO_BASE_PATH/unexport");
	}
    }

    for(my $j = $BASE_KEYSENSE_PIN; $j < $BASE_KEYSENSE_PIN + $KEYS_PER_REGION; ++$j) {
	for(my $k = 0; $k < $DUPS_PER_KEY; ++$k) {
	    my $pin = $j + $k * $KEYS_PER_REGION;
	    if(-d "$GPIO_BASE_PATH/gpio$pin") {
		trace("SETUP","Unexporting pin $pin");
		system("echo $pin > $GPIO_BASE_PATH/unexport");
	    }
	}
    }

    if($ENABLE_MIDI) {
	trace("SETUP", "Turning all MIDI notes off");

	for(my $i = $MIDI_BASE; $i < $MIDI_BASE + $REGION_COUNT * $KEYS_PER_REGION; ++$i) {
	    if($key_state{$i} != 0) {
		trace("SETUP", "Turning off MIDI note $i");
		for(my $c = 0; $c < $num_midi_channels; ++$c) {
		    MidiSerial::note_off($c, $i);
		}
	    }
	}

	trace("SETUP", "Tearing down MIDI interface");
	MidiSerial::teardown(0);
    }
    
    exit(0);
}

$SIG{INT} = \&termination;

# Do initial setup, exporting all needed keys
for(my $i = $BASE_CONTROL_PIN; $i < $BASE_CONTROL_PIN + $REGION_COUNT; ++$i) {
    if (! -d "$GPIO_BASE_PATH/gpio$i") {
	trace("SETUP","Exporting pin $i");
	system("echo $i > $GPIO_BASE_PATH/export");
    }
    system("echo high > $GPIO_BASE_PATH/gpio$i/direction");
    trace("SETUP","Marking gpio$i as output, starting high.");
}

for(my $j = $BASE_KEYSENSE_PIN; $j < $BASE_KEYSENSE_PIN + $KEYS_PER_REGION; ++$j) {
    for(my $k = 0; $k < $DUPS_PER_KEY; ++$k) {
	my $pin = $j + $k * $KEYS_PER_REGION;
	if(! -d "$GPIO_BASE_PATH/gpio$pin") {
	    trace("SETUP","Exporting pin $pin");
	    system("echo $pin > $GPIO_BASE_PATH/export");
	}
	system("echo in > $GPIO_BASE_PATH/gpio$pin/direction");
	trace("SETUP","Marking gpio$pin as input.");
    }
}


my $key = $MIDI_BASE;
for(my $i = 0; $i < $REGION_COUNT; ++$i) {
    for(my $j = 0; $j < $KEYS_PER_REGION; ++$j) {
	$key_state{$key} = 0;
	$max_key_state{$key} = 0;
	++$key;
    }
}

if($ENABLE_MIDI) {
    trace("SETUP", "Setting up MIDI interface");
    MidiSerial::setup($MIDI_SERIAL_PORT, undef);

    # Set up the various instruments, for each channel
    trace("SETUP", "Setting up MIDI instruments");
    
    if(scalar @MIDI_INSTRUMENTS > 16) {
	die "ERROR: Too many MIDI instruments specified!\n";
    }
    
    foreach(@MIDI_INSTRUMENTS) {
	trace("SETUP", "Setting MIDI channel $num_midi_channels to instrument $_");
	MidiSerial::program_change($num_midi_channels, $_);
	++$num_midi_channels;	    
    }
}

sub set_pin {
    my ($pin, $value) = @_;

#    system("echo $value > $GPIO_BASE_PATH/gpio$pin/value");

    my $fh;
    open($fh, ">$GPIO_BASE_PATH/gpio$pin/value");
    print $fh $value;
    close($fh);
}

sub read_pin {
    my ($pin) = @_;

#    my ($value) = `cat $GPIO_BASE_PATH/gpio$pin/value`;
#    chomp $value;

    my $fh;
    open($fh, "<$GPIO_BASE_PATH/gpio$pin/value");
    my $value;
    read $fh, $value, 1;
    close($fh);
    
    return $value;
}



trace("SETUP","Setup complete. Starting scans.\n");

$true_start = Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC());
while(1) {
    # record the time we started
    my $started_iteration = Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC());
#    trace("NOTE: Starting iteration at $started_iteration\n";

#    my $actual_start = Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC());
    # scan through all regions
    my $key = $MIDI_BASE;
    for(my $i = $BASE_CONTROL_PIN; $i < $BASE_CONTROL_PIN + $REGION_COUNT; ++$i) {

	# signal we are scanning this region now
	set_pin($i, 0);
	
	for(my $j = $BASE_KEYSENSE_PIN; $j < $BASE_KEYSENSE_PIN + $KEYS_PER_REGION; ++$j) {
	    # Read up a new key state
	    my $old_state = $key_state{$key};
	    my $cur_state = 0;
	    for(my $k = 0; $k < $DUPS_PER_KEY; ++$k) {
		my $pin = $j + $k * $KEYS_PER_REGION;

		# Check the state of this pin
		my $value = read_pin($pin);
		$cur_state += (($value?0:1) << $k);
	    }

	    # update the key state tables.
	    $key_state{$key} = $cur_state;
	    $max_key_state{$key} = $cur_state if $cur_state > $max_key_state{$key};
	    if($cur_state) {
		$cur_keys{$key} = 1;
	    } else {
		delete $cur_keys{$key};
	    }
	    
	    # if the key state has changed, output that fact
	    if($old_state != $cur_state) {
		trace("EVENT","$key was $old_state, now $cur_state");

		if($ENABLE_MIDI) {
		    if($old_state == 0) {
			if($cur_state == 1) {
			    # Turn on the key in all instruments, quietly
			    for(my $c = 0; $c < $num_midi_channels; ++$c) {
				MidiSerial::note_on($c, $key, $MIDI_QUIET);
			    }
			} elsif($cur_state == 3) {
			    # Turn on the key in all instruments, loudly
			    for(my $c = 0; $c < $num_midi_channels; ++$c) {
				MidiSerial::note_on($c, $key, $MIDI_LOUD);
			    }
			}
		    } elsif($cur_state == 0) {
			# Turn off the key in all instruments
			for(my $c = 0; $c < $num_midi_channels; ++$c) {
			    MidiSerial::note_off($c, $key);
			}
		    }
		}
	    }

	    if($SHOW_CHORDS) {
		my $old_chord = $cur_chord;
		$cur_chord = calcChord();

		if($cur_chord ne $old_chord) {
		    trace("CHORD", $cur_chord);
		}
	    }
	    
	    ++$key;
	}

	# Signal we're done scanning this region
	set_pin($i, 1);
    }


    # sleep for the rest of my duration, or report that I'm behind schedule
    my $ended_iteration = Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC());
    my $duration = $ended_iteration - $started_iteration;
    if($duration < $SCAN_PERIOD) {
	# need to sleep for a bit
	smartsleep($started_iteration, $ended_iteration, $SCAN_PERIOD);
    } elsif($duration > $SCAN_PERIOD) {
	# Gah! took too long!
	trace("WARN", "Missed scan period by ".($duration - $SCAN_PERIOD)." seconds.  Actual work took $duration seconds.");
    }

    ++$iterations;
    $scan_time += $duration;
}

exit(0);

sub smartsleep {
    my ($started, $ended, $period) = @_;

#    Time::HiRes::clock_nanosleep(Time::HiRes::CLOCK_MONOTONIC(), ($started + $period)*1e9, Time::HiRes::TIMER_ABSTIME());
#    return;
    
    # or...
    if($ended - $started > $period) {
	return;
    } elsif($ended - $started - $period > $SPIN_MAX) {
	# proper sleep, but a bit early, then spin
	Time::HiRes::clock_nanosleep(Time::HiRes::CLOCK_MONOTONIC(), ($started + $period - $SPIN_MAX)*1e9, Time::HiRes::TIMER_ABSTIME());
    }

    # hard spin for the rest of the time
    while(Time::HiRes::clock_gettime(Time::HiRes::CLOCK_MONOTONIC()) < $started + $period) {
    }
}

sub calcKey {
    my ($key) = @_;

    my $class = $key % 12;
    my $octave = ($key - $class) / 12 - 1;

    my $keyclass = $key_classes[$class];

    return "$keyclass$octave";
}

sub calcChord {
    my @keys = ();

    foreach(sort {$a <=> $b} keys %cur_keys) {
	push @keys, calcKey($_);
    }

    return join(' ', @keys);
}
