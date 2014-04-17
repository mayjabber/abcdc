#!/usr/bin/env perl
#author:        zwj@skybility.com
#version:       1.4.2
#last modfiy:   2014-04-10
#This script is tcp status from netstat and alarm when it is over threshold.
#changelog:
#    0.1 tcp连接状态计数监控脚本
#    0.2 加入发送报警的功能
#    0.3 实现详细计数和排序
#    0.4 实现 local和foreign address 分别统计;实现UDP报警信息发送
#    0.5 添加deamon代码
#    0.6 实现daemon功能，通过参数选择启动方式
#    0.7 判断AIX下的ipv4连接关键字tcp4
#    0.8 增加debug调试日志
#    0.9 完善debug日志，完善sig屏蔽
#    1.0 增加对Recv-Q和Send-Q的监控
#    1.1 去除daemon方式运行时做sudo切换用户的操作
#    1.2 增加TCP连接统计信息发送
#    1.2.1 修改fork方式，保证只有一个后台进程运行
#    1.3 支持windows上运行
#    1.3.1 修复sles10上面取程序和用户名都是unknow的问题;增加报警和发送tcp连接信息的开关;在程序里加入报警阀值默认配置，无配置文件时使用默认配置。
#    1.4 支持aix上运行
#    1.4.1 发送报警和连接信息的地址配置项放到脚本开头
#    1.4.2 添加单次运行的功能，使用 -c 参数指定运行次数

use strict;
use warnings;
use IO::Socket;
use POSIX 'setsid';
use Time::Piece;

# 刷新间隔
my $_refresh_rate = 5; #Refresh rate of the netstat data

use FindBin qw($Bin);
my $cfg_file = "$Bin/tcp_monitor.conf";

# debug开关，debug日志文件名
my $debug = 1;
my $debuglog = "$Bin/tcp_monitor.log";

# 报警开关
my $alarm_switch = 1;
my $alarm_ip = "10.237.128.195";
my $alarm_port = 31820;

# 发送tcp连接信息开关
my $report_switch = 1;
my $report_ip = "192.168.3.128";
my $report_port = 31830;

# read and set default config
my %threshold;

if (-r $cfg_file)
{
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
}

# decide OS
use English;

my $os = $^O;
my $os_linux = 'linux';
my $os_win = 'MSWin32';
my $os_aix = 'aix';


my $tcp_at = 0;
my $tcp_recv_at = 1;
my $tcp_send_at = 2;
my $local_address_at = 3;
my $foreign_address_at = 4;
my $tcp_state_at = 5;

my $netstat_cmd = '/usr/bin/env netstat -atn';

if ($os eq $os_linux)
{
}
elsif ($os eq $os_win)
{
$netstat_cmd = 'C:\Windows\System32\NETSTAT -ano -p tcp';
}
elsif ($os eq $os_aix)
{
}


sub get_netstat
{   
    my @stats;
    #Call the netstat utility and split the output into separate lines 
    my @lines = `$netstat_cmd`;
    #Iterate through the netstat output looking for the 'tcp' keyword in the tcp_at 
    # position and the state information in the tcp_state_at position. Count each 
    # occurance of each state.
    #If 'tcp4' in the tcp_at,the OS may Unix, 'tcp4' is the keyword
#    my $keyword = 'tcp';
#    foreach my $tcp (@lines)
#    {
#        if ($tcp eq '')
#        {
#            next;
#        }
#        my @line = split /\s+/, $tcp;
#        if ($line[$tcp_at] eq 'tcp6')
#        {
#            $keyword = 'tcp';
#            last;
#        }
#        elsif ($line[$tcp_at] eq 'tcp4')
#        {
#            $keyword = 'tcp4';
#            last;
#        }
#    }

    foreach my $tcp (@lines)
    {
        # skip empty lines 
        my @line = split /\s+/, $tcp;
        if (scalar @line < 5)
        {
            next;
        }
        if ($os ne $os_win)
        {
            if ($line[$tcp_at] =~ /tcp4?/ and $line[$local_address_at] =~ /\d+\.\d+\.\d+\.\d+[:\.]\d+/)
            {
                push @stats, $tcp;
            }
        }
        else
        {
            if ($line[2] =~ /\d+\.\d+\.\d+\.\d+[:\.]\d+/)
            {
                if ($line[4] eq 'LISTENING'){$line[4] = 'LISTEN';}
                push @stats, "$line[1] 0 0 $line[2] $line[3] $line[4] $line[5]";
            }
        }
    }
    return @stats;
}

sub warning_data
{
    my @lines = @_;
    my %tempconns;
    foreach my $tcp (@lines)
    {
        my @line = split /\s+/, $tcp;
        if (! exists $tempconns{$line[$tcp_state_at]})
        {
            $tempconns{$line[$tcp_state_at]} = {"total" => 0,
                                                "local" => {},
                                                "foreign" => {},
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
        
        # add Recv-Q and Send-Q count
        if (! exists $tempconns{"Recv-Q"})
        {
            $tempconns{"Recv-Q"} = {"total" => 0,
                                    "local" => {},
                                    "foreign" => {},
                                    };
            $tempconns{"Send-Q"} = {"total" => 0,
                                    "local" => {},
                                    "foreign" => {},
                                    };
        }
        if ($tempconns{"Recv-Q"}{"total"} < $line[$tcp_recv_at]){$tempconns{"Recv-Q"}{"total"} = $line[$tcp_recv_at];}
        if ($tempconns{"Send-Q"}{"total"} < $line[$tcp_send_at]){$tempconns{"Send-Q"}{"total"} = $line[$tcp_send_at];}
        if (! exists $tempconns{"Recv-Q"}{"local"}{$line[$local_address_at]})
        {
            $tempconns{"Recv-Q"}{"local"}{$line[$local_address_at]} = 0;
            $tempconns{"Recv-Q"}{"foreign"}{$line[$foreign_address_at]} = 0;
            $tempconns{"Send-Q"}{"local"}{$line[$local_address_at]} = 0;
            $tempconns{"Send-Q"}{"foreign"}{$line[$foreign_address_at]} = 0;
        }
        if ($tempconns{"Recv-Q"}{"local"}{$line[$local_address_at]} < $line[$tcp_recv_at])
        {
            $tempconns{"Recv-Q"}{"local"}{$line[$local_address_at]} = $line[$tcp_recv_at];
            $tempconns{"Recv-Q"}{"foreign"}{$line[$foreign_address_at]} = $line[$tcp_recv_at];
        }
        if ($tempconns{"Send-Q"}{"local"}{$line[$local_address_at]} < $line[$tcp_send_at])
        {
            $tempconns{"Send-Q"}{"local"}{$line[$local_address_at]} = $line[$tcp_send_at];
            $tempconns{"Send-Q"}{"foreign"}{$line[$foreign_address_at]} = $line[$tcp_send_at];
        }
    }
    return %tempconns;
}

sub report_data
{
    my @lines = @_;
    my %tcp_map;
    # get listening port
    my %l_port;
    foreach my $tcp (@lines)
    {
        my @line = split /\s+/, $tcp;
        if ($line[$tcp_state_at] eq 'LISTEN')
        {
            $line[$local_address_at] =~ /(\d+)$/;
            $l_port{$1} = 1;
        }
    }

    foreach my $tcp (@lines)
    {
        my @line = split /\s+/, $tcp;
        if ($line[$tcp_state_at] eq 'LISTEN')
        {next;}
        
        #decide side
        my $side = 'server';
        $line[$local_address_at] =~ /(\d+)$/;
        my $port = $1;
        if (! exists $l_port{$port})
        {
            $side = 'client';
            $line[$foreign_address_at] =~ /(\d+)$/;
            $port = $1;
        }

        #create hash
        $line[$local_address_at] =~ /(.+)[:\.]\d+$/;
        my $lip = $1;
        $line[$foreign_address_at] =~ /(.+)[:\.]\d+$/;
        my $fip = $1;
        if (! exists $tcp_map{"$side^$port^$lip^$fip"})
        {
            $tcp_map{"$side^$port^$lip^$fip"} = {
                'recvq' => 0,
                'sendq' => 0,
                'ESTABLISHED' => 0,
                'SYN_SENT' => 0,
                'SYN_RECV' => 0,
                'SYN_WAIT' => 0,
                'FIN_WAIT1' => 0,
                'FIN_WAIT2' => 0,
                'TIME_WAIT' => 0,
                'CLOSE' => 0,
                'CLOSE_WAIT' => 0,
                'LAST_ACK' => 0,
                'CLOSING' => 0,
                'UNKNOWN' => 0,
                'pid' => 0
            };
            if ($os eq $os_win)
            {
                $tcp_map{"$side^$port^$lip^$fip"}{'pid'} = $line[6];
            }
        }
        else
        {
            $tcp_map{"$side^$port^$lip^$fip"}{$line[$tcp_state_at]} += 1;
            $tcp_map{"$side^$port^$lip^$fip"}{'recvq'} += $line[$tcp_recv_at];
            $tcp_map{"$side^$port^$lip^$fip"}{'sendq'} += $line[$tcp_send_at];
            if ($os eq $os_win and $tcp_map{"$side^$port^$lip^$fip"}{'pid'} eq '0')
            {
                $tcp_map{"$side^$port^$lip^$fip"}{'pid'} = $line[6];
            }
        }
    }
    return %tcp_map;
}

#get connect command name and user
my %comlist;
sub get_name
{
    my $conn = shift;
    my $pid = shift;
    if (exists $comlist{$conn} and $comlist{$conn} ne 'unknown^unknown')
    {
        return $comlist{$conn};
    }else{
        $comlist{$conn} = 'unknown^unknown';
        if ($os ne $os_win)
        {
            my ($side,$port,$lip,$fip) = split /\^/,$conn;
            my @lsof;
            if ($os eq $os_aix)
            {
                if (-x '/openimis/SysChk/bin/lsof' )
                {
                    @lsof = `/openimis/SysChk/bin/lsof -nP +c 0 -i 4TCP:$port`;
                }
                else
                {
                    print 'Warning: not found lsof in /openimis/SysChk/bin/lsof ';
                    return $comlist{$conn};
                }
            }
            else
            {
                @lsof = `/usr/bin/env lsof -nP +c 0 -i 4TCP:$port`;
            }
            my $partern;
            if ($side eq 'server')
            {
                $partern = "$lip:$port->$fip:\\d+";
            }else{
                $partern = "$lip:\\d+->$fip:$port";
            }
            foreach (@lsof)
            {
                my @line = split /\s+/,$_;
                if ($_ =~ /$partern/)
                {
                    $comlist{$conn} = "$line[0]^$line[2]";
                    last;
                }
            }
        }
        else
        {
            my @tasklist = `C:\\Windows\\System32\\tasklist.exe -v`;
            foreach (@tasklist)
            {
                my @line = split /\s+/,$_;
                if (scalar @line < 7)
                {
                    next;
                }
                if ($line[1] eq $pid)
                {
                    if ($line[7] eq 'NT')
                    {
                        $comlist{$conn} = "$line[0]^NT $line[8]";
                    }
                    else
                    {
                        $comlist{$conn} = "$line[0]^$line[7]";
                    }
                    last;
                }
            }
        }
    }
    return $comlist{$conn};
}

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
    my $s = IO::Socket::INET->new(PeerPort =>$alarm_port,
                     Proto =>'udp',
                     PeerAddr =>$alarm_ip) || print "socket error!\n";

    print $str."\n";
    $s->send("$str");
    close $s;
}

#发送连接数报告
sub sendReport
{
    my $str = shift;
    my $s = IO::Socket::INET->new(PeerPort =>$report_port,
                     Proto =>'udp',
                     PeerAddr =>$report_ip) || print "socket error!\n";

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
    'Recv-Q' => {
        'ServerID'=>'tcp_recv_q',
        'WarnID'=>'0014',
        'count'=>0},
    'Send-Q' => {
        'ServerID'=>'tcp_send_q',
        'WarnID'=>'0015',
        'count'=>0},
);

my $proCode = "99";
my $seqID = "";
use Sys::Hostname;
my $hostID = hostname;
my $project = "";
my $source = "TCPMON";
my $relType = "";
my $relID = "";
my $relText = "";

sub do_check
{
    my $t = localtime;
    my $date = $t->ymd('');
    my $time = $t->hms('');
    my @stats = &get_netstat;
    my %conns = &warning_data(@stats);
    my %tcp_map = &report_data(@stats);
    if ($debug){
        use Data::Dumper;
        open LOG, ">>$debuglog" || print "open $debuglog file error!\n";
        print LOG "时间:$date $time\n";
        #print LOG "数据采集:\n";
        #print LOG Dumper(%conns);
        #print Dumper(%tcp_map);
    }
    
    #生成统计报文
    if ($report_switch){
        my $msghead = "SYSTEMLOG|TCPNETSTAT|$hostID|";
        my $report = '';
        foreach my $conn (keys %tcp_map)
        {
            if (length $report > 0)
            {
                if (length $report > 3500)
                {
                    &sendReport($msghead.$report);
                    $report = '';
                }else{
                    $report .= '#^#';
                }
            }
            my $name_and_user = &get_name($conn,$tcp_map{$conn}{'pid'});
            my ($side,$port,$lip,$fip) = split /\^/,$conn;
            my $address;
            if ($side eq 'server')
            {
                $address = "$side^$lip^$port^$fip^";
            }else{
                $address = "$side^$lip^^$fip^$port";
            }
            my $msgbody = "$date$time^tcp^$address^$tcp_map{$conn}{'recvq'}^$tcp_map{$conn}{'sendq'}^$tcp_map{$conn}{'ESTABLISHED'}^$tcp_map{$conn}{'TIME_WAIT'}^$tcp_map{$conn}{'CLOSE_WAIT'}^$tcp_map{$conn}{'SYN_SENT'}^$tcp_map{$conn}{'SYN_RECV'}^$tcp_map{$conn}{'SYN_WAIT'}^$tcp_map{$conn}{'FIN_WAIT1'}^$tcp_map{$conn}{'FIN_WAIT2'}^$tcp_map{$conn}{'CLOSE'}^$tcp_map{$conn}{'LAST_ACK'}^$tcp_map{$conn}{'CLOSING'}^$tcp_map{$conn}{'UNKNOWN'}^$name_and_user^^^";
            if ($debug)
            {
                print LOG "连接统计 $msgbody\n";
            }
            $report .= $msgbody;
        }
        if (length $report > 0)
        {
            &sendReport($msghead.$report);
        }
    }

    #生成报警报文
    if ($alarm_switch){
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
                my $warnShortMsg = '';
                my @localSort = &sortSum(%{$conns{$stat}{"local"}});
                my @foreignSort = &sortSum(%{$conns{$stat}{"foreign"}});
                if ($stat ne "Recv-Q" and $stat ne "Send-Q")
                {
                    $warnDetailMsg .= 'Local Address:';
                    foreach (@localSort)
                    {
                        if ($conns{$stat}{"local"}{$_} == 0)
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
                        if ($conns{$stat}{"foreign"}{$_} == 0)
                        {
                            last;
                        }
                        else
                        {
                            $warnDetailMsg .= "$_ $conns{$stat}{'foreign'}{$_}个、"
                        }
                    }
                    $warnShortMsg = "TCP Netstat 发现处于$stat状态的链接数为$warnValue超过阀值$threshold{$stat}{$level}，请关注，处于此状态的链接前五个为：$warnDetailMsg";
                }else{
                    $warnDetailMsg .= 'Local Address:';
                    foreach (@localSort)
                    {
                        if ($conns{$stat}{"local"}{$_} == 1)
                        {
                            last;
                        }
                        elsif (&level($stat,$conns{$stat}{'local'}{$_}) eq "normal")
                        {
                            last;
                        }
                        else
                        {
                            $warnDetailMsg .= "$_ $conns{$stat}{'local'}{$_}、"
                        }
                    }
                    $warnDetailMsg .= ' Foreign Address:';
                    foreach (@foreignSort)
                    {
                        if ($conns{$stat}{"foreign"}{$_} == 1)
                        {
                            last;
                        }
                        elsif (&level($stat,$conns{$stat}{'foreign'}{$_}) eq "normal")
                        {
                            last;
                        }
                        else
                        {
                            $warnDetailMsg .= "$_ $conns{$stat}{'foreign'}{$_}、"
                        }
                    }
                    $warnShortMsg = "TCP Netstat 发现$stat的值为$warnValue超过阀值$threshold{$stat}{$level}，请关注，处于此状态的链接前五个为：$warnDetailMsg";
                }

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
                if (!exists $stats{$stat})
                {
                    print "Warning: unknow tcp status '$stat'.\n";
                }
                if ($debug)
                {
                    print LOG "报警信息($stat 计数:$stats{$stat}{'count'}):总数$conns{$stat}{'total'},低于阀值，重置报警计数为0\n";
                }
                $stats{$stat}{'count'} = 0;
            }
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
elsif ($ARGV[0] eq '-c' and $ARGV[1] =~ /\d+/)
{
    my $count = $ARGV[1];
    print "start and run $count times...\n\n";
    while($count > 0) {
        &do_check;
        $count -= 1;
        if ($count < 1){last;}
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
    my $pid = fork;
    if ($pid == 0)
    {
        exit;
    }
    else
    {
        while(1) {
            &do_check;
            sleep $_refresh_rate;
        }
    }
}
else
{
    print "usage:\n";
    print "    -d          start as daemon\n";
    print "    -c COUNT    run COUNT times\n";
    exit;
}

# main end

