#!/usr/bin/env perl
#author:        zwj@skybility.com
#version:       0.9
#last modfiy:   2013-12-10
#This script is tcp status from netstat and alarm when it is over threshold.

use strict;
use warnings;
use autodie;
use IO::Socket;
use POSIX 'setsid';

our $USER = 'root';
our $GROUP = 'root';
my $_refresh_rate = 5; #Refresh rate of the netstat data

use FindBin qw($Bin);
my $cfg_file = "$Bin/tcp_monitor.conf";

my $debug = 1;
my $debuglog = "$Bin/tcp_monitor.log";

 

sub netstat
{ 
    #Array positions for the connection type and state data 
    # acquired from the netstat output. 
    my $tcp_at = 0;
    my $tcp_state_at = 5;
    my $local_address_at = 3;
    my $foreign_address_at = 3;
    
    my %tempconns;
    
    #Call the netstat utility and split the output into separate lines 
    my @lines = `netstat -atn`;
    #Iterate through the netstat output looking for the 'tcp' keyword in the tcp_at 
    # position and the state information in the tcp_state_at position. Count each 
    # occurance of each state.
    #If 'tcp4' in the tcp_at,the OS may Unix, 'tcp4' is the keyword
    my $keyword = 'tcp';
    foreach my $tcp (@lines)
    {
        if ($tcp eq '')
        {
            next;
        }
        my @line = split /\s+/, $tcp;
        if ($line[$tcp_at] eq 'tcp6')
        {
            $keyword = 'tcp';
            last;
        }
        elsif ($line[$tcp_at] eq 'tcp4')
        {
            $keyword = 'tcp4';
            last;
        }
    }

    foreach my $tcp (@lines)
    {
        # skip empty lines 
        if ($tcp eq '')
        {
            next;
        }
        my @line = split /\s+/, $tcp;
        if ($line[$tcp_at] eq $keyword)
        {
            if (! exists $tempconns{$line[$tcp_state_at]})
            {
                $tempconns{$line[$tcp_state_at]} = {"total" => 0,
                                                    "local" => {},
                                                    "foreign" => {} 
                                                    };
            }
            if (! exists $tempconns{$line[$tcp_state_at]}{"local"}{$line[$local_address_at]})
            {
                $tempconns{$line[$tcp_state_at]}{"local"}{$line[$local_address_at]} = 0;
                $tempconns{$line[$tcp_state_at]}{"foreign"}{$line[$foreign_address_at]} = 0;
            }
            $tempconns{$line[$tcp_state_at]}{"total"} += 1;
            $tempconns{$line[$tcp_state_at]}{"local"}{$line[$local_address_at]} += 1;
            $tempconns{$line[$tcp_state_at]}{"foreign"}{$line[$foreign_address_at]} += 1;
        }
    }
    return %tempconns;
}

#read conf
my %threshold;
open FD, $cfg_file;
while(<FD>)
{
    chomp;
    if (/^\s*#/ or /^\s*$/){next;}
    my @arry = split(/\s+/,$_);
    $threshold{$arry[0]} = {
        'warning' => $arry[1],
        'alarm' => $arry[2]
    };
}
close FD;

sub level
{
    my ($name, $value) = @_;
    my $level = 'normal';
    if (exists $threshold{$name})
    {
        if ($value >= $threshold{$name}{'alarm'})
        {
            $level = 'alarm';
        }
        elsif ($value >= $threshold{$name}{'warning'})
        {
            $level = 'warning';
        }
    }
    return $level;
}

sub sortSum
{
    my %hash = @_;
    my @result;
    foreach my $address (keys %hash)
    {
        my $n = 0;
        foreach (@result)
        {
            if ($hash{$address} >= $hash{$_})
            {
                splice @result, $n, 0, ($address);
                last;
            }
            $n += 1;
        }
        if (@result == 0)
        {
            push @result, $address;
        }
    }
    return @result;
}

sub sendUDP  #发送报警
{
    my $str = shift;
    my $warnip = "10.237.128.195";
    my $s = IO::Socket::INET->new(PeerPort =>'31820',
                     Proto =>'udp',
                     PeerAddr =>$warnip) || die "socket error!\n";

    print $str."\n";
    $s->send("$str");
    close $s;
}

my %stats = (
    'LISTEN' => {
        'ServerID'=>'tcp_listen',
        'WarnID'=>'0001',
        'count'=>0},
    'ESTABLISHED' => {
        'ServerID'=>'tcp_established',
        'WarnID'=>'0002',
        'count'=>0},
    'TIME_WAIT' => {
        'ServerID'=>'tcp_time_wait',
        'WarnID'=>'0003',
        'count'=>0},
    'CLOSE_WAIT' => {
        'ServerID'=>'tcp_close_wait',
        'WarnID'=>'0004',
        'count'=>0},
    'SYN_SENT' => {
        'ServerID'=>'tcp_syn_sent',
        'WarnID'=>'0005',
        'count'=>0},
    'SYN_RECV' => {
        'ServerID'=>'tcp_syn_recv',
        'WarnID'=>'0006',
        'count'=>0},
    'SYN_WAIT' => {
        'ServerID'=>'tcp_syn_wait',
        'WarnID'=>'0007',
        'count'=>0},
    'FIN_WAIT1' => {
        'ServerID'=>'tcp_fin_wait1',
        'WarnID'=>'0008',
        'count'=>0},
    'FIN_WAIT2' => {
        'ServerID'=>'tcp_fin_wait2',
        'WarnID'=>'0009',
        'count'=>0},
    'CLOSED' => {
        'ServerID'=>'tcp_closed',
        'WarnID'=>'0010',
        'count'=>0},
    'LAST_ACK' => {
        'ServerID'=>'tcp_last_ack',
        'WarnID'=>'0011',
        'count'=>0},
    'CLOSING' => {
        'ServerID'=>'tcp_closing',
        'WarnID'=>'0012',
        'count'=>0},
    'unknown' => {
        'ServerID'=>'tcp_unknown',
        'WarnID'=>'0013',
        'count'=>0},
);

my $proCode = "99";
my $seqID = "";
my $hostID = `hostname`;
chomp $hostID;
my $project = "";
my $source = "TCPMON";
my $relType = "";
my $relID = "";
my $relText = "";

sub do_check
{
    my $date = `date +%Y%m%d`;
    my $time = `date +%H%M%S`;
    chomp($date, $time);
    my %conns = &netstat;
    if ($debug){
        use Data::Dumper;
        open LOG, ">>$debuglog";
        print LOG "时间:$date $time\n";
        #print LOG "数据采集:\n";
        #print LOG Dumper(%conns);
    }
    foreach my $stat (keys %conns)
    {
        my $level = &level($stat,$conns{$stat}{'total'});
        if ($level ne "normal")
        {
            $stats{$stat}{'count'} += 1;
            if ($stats{$stat}{'count'} > 10){
                if ($debug)
                {
                    print LOG "报警信息($stat 计数:$stats{$stat}{'count'}):总数$conns{$stat}{'total'},报警次数超过上限10,跳过\n";
                }
                next;
            }
            my $warnValue = $conns{$stat}{'total'};
            my $serverID = $stats{$stat}{"ServerID"};
            my $warnID = $stats{$stat}{"WarnID"};
            
            my ($warnLevel, $warnText);
            if ($level eq "warning")
            {
                $warnLevel = "0004";
                $warnText = "一般报警";
            }
            else
            {
                $warnLevel = "0005";
                $warnText = "严重报警";
            }

            my $warnDetailMsg = '';
            my @localSort = &sortSum(%{$conns{$stat}{"local"}});
            my @foreignSort = &sortSum(%{$conns{$stat}{"foreign"}});
            $warnDetailMsg .= 'Local Address:';
            foreach (@localSort)
            {
                if ($conns{$stat}{"local"}{$_} == 1)
                {
                    last;
                }
                else
                {
                    $warnDetailMsg .= "$_ $conns{$stat}{'local'}{$_}个、"
                }
            }
            $warnDetailMsg .= ' Foreign Address:';
            foreach (@foreignSort)
            {
                if ($conns{$stat}{"foreign"}{$_} == 1)
                {
                    last;
                }
                else
                {
                    $warnDetailMsg .= "$_ $conns{$stat}{'local'}{$_}个、"
                }
            }
            my $warnShortMsg = "TCP Netstat 发现处于$stat状态的链接数为$warnValue超过阀值$threshold{$stat}{$level}，请关注，处于此状态的链接前五个为：$warnDetailMsg";

            my $msg = "CUSTOM^$proCode^$date^$time^$seqID^$hostID^$serverID^$project^$source^$warnValue^$warnID^$warnLevel^$warnText^$warnShortMsg^$warnDetailMsg^$relType^$relID^$relText";
            if ($debug)
            {
                print LOG "报警信息($stat 计数:$stats{$stat}{'count'}):$msg\n";
            }
            print "$msg\n";
            &sendUDP("$msg");
        }
        else
        {
            if ($debug)
            {
                print LOG "报警信息($stat 计数:$stats{$stat}{'count'}):总数$conns{$stat}{'total'},低于阀值，重置报警计数为0\n";
            }
            $stats{$stat}{'count'} = 0;
        }
    }
    if ($debug)
    {
        close LOG;
    }
}

#main begin
if (!exists $ARGV[0])
{
    print "start normal...\n\n";
    while(1) {
        &do_check;
        sleep $_refresh_rate;
    }
}
elsif ($ARGV[0] eq '-d')
{
    print "start as daemon...\n\n";
    #------------------------------
    # create daemon process
    exit if fork;

    &setsid();

    # fork() again so the parent (session group leader) can exit.
    exit if fork;

    # chdir('/') to ensure our daemon doesn't keep any directory in use.
    chdir '/';

    # close() fds 0, 1, and 2.
    close STDIN;
    close STDOUT;
    close STDERR;

    # redirect fds 0, 1, and 2 to /dev/null
    open STDIN, '/dev/null';
    open STDOUT, '>/dev/null';
    open STDERR, '>/dev/null';

    # function to change user and group
    sub sudo {
        my ($user, $group) = @_;
        my $uid = (getpwnam($user))[2];
        my $gid = (getgrnam($group))[2];
        ($(, $)) = ($gid, "$gid $gid");
        ($<, $>) = ($uid, $uid);
    }    

    # change to daemon user and group.
    &sudo($USER, $GROUP);

    # ignore SIGCHLD signal to avoid zombie processes
    $SIG{CHLD} = 'IGNORE';
    $SIG{'INT'}  = 'IGNORE';
    $SIG{'QUIT'} = 'IGNORE';
    $SIG{'ALRM'} = 'IGNORE';
    $SIG{'ILL'}  = 'IGNORE';
    $SIG{'ABRT'} = 'IGNORE';
    $SIG{'FPE'}  = 'IGNORE';
    $SIG{'SEGV'} = 'IGNORE';
    $SIG{'TERM'} = 'IGNORE';
    $SIG{'BUS'}  = 'IGNORE';
    $SIG{'SYS'}  = 'IGNORE';
    $SIG{'XCPU'} = 'IGNORE';
    $SIG{'XFSZ'} = 'IGNORE';
    $SIG{'IOT'}  = 'IGNORE';
    $SIG{'PIPE'} = 'IGNORE';
    $SIG{'HUP'}  = 'IGNORE';

    # start main loop.
    while(1) {
        my $pid = fork;
        if ($pid == 0)
        {
            &do_check;
            exit;
        }
        else
        {
            sleep $_refresh_rate;
        }
    }
}
else
{
    print "usage:\n -d  start as daemon\n";
    exit;
}

# main end

