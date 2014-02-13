package Net::ISP::Balance;

use strict;
use Net::Netmask;

use base 'Exporter';
use Carp;
our @EXPORT_OK = qw(sh get_devices);
our @EXPORT    = @EXPORT_OK;

our $VERSION    = 0.01;
our $VERBOSE    = 0;
our $DEBUG_ONLY = 0;

# e.g. sh "ip route flush table main";
sub sh ($) {
    my $arg = shift;
    chomp($arg);
    carp $arg   if $VERBOSE;
    if ($DEBUG_ONLY) {
	$arg .= "\n";
	print $arg;
    } else {
	system $arg;
    }
}

# e.g.
# my $D     = get_devices(
#                  LAN   => [LAN_DEVICE()   => 'lan'],
#                  CABLE => [CABLE_DEVICE() => 'wan'],
#                  DSL   => [DSL_DEVICE()   => 'wan']);
#
sub get_devices {
    my %d = @_;
    my (%ifaces,%iface_type);
    # use /etc/network/interfaces to figure out what kind of
    # device each is.
    open my $f,'/etc/network/interfaces' or die "/etc/network/interfaces: $!";
    while (<$f>) {
	chomp;
	if (/^\s*iface\s+(\w+)\s+inet\s+(\w+)/) {
	    $iface_type{$1} = $2;
	}
    }
    close $f;
    my $counter = 0;
    for my $label (keys %d) {
	my ($device,$role) = @{$d{$label}};
	my $type = $iface_type{$device};
	my $info = $type eq 'static' ? get_static_info($device)
	          :$type eq 'dhcp'   ? get_dhcp_info($device)
	          :$type eq 'ppp'    ? get_ppp_info($device)
		  :undef;
	$info ||= {dev=>$device,up=>0}; # not running
	$info or die "Couldn't figure out how to get info from $device";
	if ($role eq 'wan') {
	    $counter++;
	    $info->{fwmark} = $counter;
	    $info->{table}  = $counter;
	}
	# ignore any interfaces that do not seem to be running
	next unless $info->{up};
	$ifaces{$label}=$info;
    }
    return \%ifaces;
}

sub get_ppp_info {
    my $device   = shift;
    my $ifconfig = `ifconfig $device` or return;
    my ($ip)     = $ifconfig =~ /inet addr:(\S+)/;
    my ($peer)   = $ifconfig =~ /P-t-P:(\S+)/;
    my ($mask)   = $ifconfig =~ /Mask:(\S+)/;
    my $up       = $ifconfig =~ /^\s+UP\s/m;
    my $block    = Net::Netmask->new($peer,$mask);
    return {up  => $up,
	    dev => $device,
	    ip  => $ip,
	    gw  => $peer,
	    net => "$block",
	    fwmark => undef,};
}

sub get_static_info {
    my $device = shift;
    my $ifconfig = `ifconfig $device` or return;
    my ($addr)   = $ifconfig =~ /inet addr:(\S+)/;
    my $up       = $ifconfig =~ /^\s+UP\s/m;
    my ($mask)   = $ifconfig =~ /Mask:(\S+)/;
    my $block    = Net::Netmask->new($addr,$mask);
    return {up  => $up,
	    dev => $device,
	    ip  => $addr,
	    gw  => $block->nth(1),
	    net => "$block",
	    fwmark => undef,};
}

sub get_dhcp_info {
    my $device = shift;
    my $leases = find_dhclient_leases($device) or die "Can't find lease file for $device";
    my $ifconfig = `ifconfig $device`;
    open my $f,$leases or die "Can't open lease file $leases: $!";

    my ($ip,$gw,$netmask);
    while (<$f>) {
	chomp;

	if (/fixed-address (\S+);/) {
	    $ip = $1;
	    next;
	}
	
	if (/option routers (\S+)[,;]/) {
	    $gw = $1;
	    next;
	}

	if (/option subnet-mask (\S+);/) {
	    $netmask = $1;
	    next;
	}
    }

    die "Couldn't find all required information" 
	unless defined($ip) && defined($gw) && defined($netmask);

    my $up       = $ifconfig =~ /^\s+UP\s/m;
    my $block = Net::Netmask->new($ip,$netmask);
    return {up  => $up,
	    dev => $device,
	    ip  => $ip,
	    gw  => $gw,
	    net => "$block",
	    fwmark => undef,
    };
}

sub find_dhclient_leases {
    my $device = shift;
    my @locations = ('/var/lib/NetworkManager','/var/lib/dhcp');
    for my $l (@locations) {
	my @matches = glob("$l/dhclient*$device.lease*");
	next unless @matches;
	return $matches[0];
    }
    return;
}

1;

