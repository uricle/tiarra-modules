# -*- mode: Perl -*-
# --------------------------------------
# Author: qux
# --------------------------------------
# Description: ����������ֻ��򤷤ޤ�
# --------------------------------------
package Tools::amds;
use lib "$ENV{HOME}/perllib";
use strict;
use base qw(Module);
use Module::Use qw(Auto::Utils);
use Auto::Utils;
use Mask;
use Multicast;
use Jcode;
use LWP::UserAgent;
use LWP::Simple;
use HTTP::Request::Common qw(GET);

my $weather_area_file = 'weather_atr.txt';

sub new {
	my ($class, %arg) = @_;
	
	my $this = {
		weather_area => undef,
	};
	my %weather_area;
	open AREA,"$weather_area_file";
	while (<AREA>) {
	    chomp;
	    my ($area,$code) = split /:/;
	    if ( $area ne "" and $code ne "" ) {
		$weather_area{$area} = $code;
	    }
	    $this->{weather_area} = \%weather_area;
	}
	close AREA;
	bless $this,$class;
	return $this;
}

sub message_arrived {
    my ($this,$msg,$sender) = @_;
    my @result = ($msg);
    
    # �����С�����Υ�å���������
#      if ($sender->isa('IrcIO::Server')) {
#      } else {
# 	 my $my_nick = $sender->current_nick;
#      }
    # PRIVMSG����
    if ($msg->command eq 'PRIVMSG') {
	my $my_nick;
	if ($sender->isa('IrcIO::Client')) {
	    $my_nick = $msg->param(0);
	} else {
	    $my_nick = $sender->current_nick;
	}
	my ($get_ch_name,undef,undef,$reply_anywhere)
	    = Auto::Utils::generate_reply_closures($msg,$sender,\@result);
	
	my $param1 = jcode($msg->param(1))->euc;
	my $reply_msg;
	my $my_alias = jcode($this->config->nick)->euc;
	if ( $param1 =~ /^(?:�������)\s*(.*)(?:��|>)(?:$my_nick|$my_alias)$/ && 
	     Mask::match_deep([$this->config->channel('all')],$msg->param(0)) ) {
	    $reply_msg = get_weather( $this, $1 );
	}
	if ( $reply_msg ne "" ) {
	    $reply_anywhere->(jcode($reply_msg)->jis);
	}
    }
    return @result;
}

sub get_weather {
    my ($this, $city) = @_;
    my $outstr = "";
    my $weather_news_base = 'http://www.jma.go.jp/jp/amedas_h/today-';
    my $weather_news_base_yesterday = 'http://www.jma.go.jp/jp/amedas_h/yesterday-';
    my $baseurl;
    my ($sec,$min,$hour,$mday,$mon,$year) = localtime(time); # ���������դ��餦��
    $year += 1900;		# ��館��ǯ��1900ǯ���ʤ��ΤǤ���
    $mon += 1;			# ��� 1 ���ʤ��ΤǤ���
    if ( $hour eq 0 ) {
		$baseurl = $weather_news_base_yesterday;
		$hour = 24;
    } else {
	$baseurl = $weather_news_base;
    }
    my $fullurl;
    if ( $city =~ /^\d+$/ ) {
	# ���ꥢ�����ɻ���
	$fullurl = $baseurl . $city . '.html';
    } else {
	# ��̾����
	if ( exists ${$this->{weather_area}}{$city} ) {
	    $fullurl = $baseurl . ${$this->{weather_area}}{$city} . '.html';
	} else {
	    return "I don't know that area:$city. please check http://www.jma.go.jp/jp/amedas_h/index.html";
	}
    }
    my $ua = LWP::UserAgent->new;
    my $my_proxy = $this->config->proxy;
    if ( $my_proxy ne "" ) {
	$ua->proxy(['http','ftp'], $my_proxy);
    }
    my $request = GET($fullurl);
    my $res = $ua->request($request);
    my $text = $res->content;#get ( $fullurl );
    $text = jcode($text)->euc;
    my %fieldname = ( '����' => -1,
		      '�߿���' => -1,
		      '����' => -1,
		      '��®' => -1,
		      '���Ȼ���' => -1,
		      '����' => -1,
		      '����' => -1 );
#     <tr>
# 	<td class="time top_left">����</td>
# 	<td class="block top bgcolor">����</td><td class="block top bgcolor">�߿���</td><td class="block top bgcolor">����</td><td class="block top bgcolor">��®</td><td class="block top bgcolor">���Ȼ���</td><td class="block top bgcolor">����</td><td class="block top bgcolor">����</td>
#     </tr>
#     <tr>
#         <td class="time left">��</td>
# 	<td class="block middle bgcolor">��</td><td class="block middle bgcolor">mm</td><td class="block middle bgcolor">16����</td><td class="block middle bgcolor">m/s</td><td class="block middle bgcolor">h</td><td class="block middle bgcolor">%</td><td class="block middle bgcolor">hPa</td>
#     </tr>
#     <tr>
# 	<td class="time left">1</td>
# 	<td class="block middle">12.1</td><td class="block middle">0.0</td><td class="block middle">������</td><td class="block middle">1</td><td class="block middle">&nbsp;</td><td class="block middle">80</td><td class="block middle">1012.9</td>
#     </tr>
    my $oclock = 0;
    my $outstr = "";
    my ($time,$temper,$rainfall,$dirwind,$windspeed,$humidity,$sunlight,$pressure,$snow);
    my $got = 0;
    my ($year,$month,$day);
    foreach ( split/\n/, $text ) {
	chomp;
	if ( /<title>(\d+)ǯ(\d+)��(\d+)��(.*?)\(/ ) {
	    $year = $1;
	    $month = $2;
	    $day = $3;
	    my $areaname = $4;
	    $areaname =~ s/��//g;
	    $outstr = "$year/$month/$day $areaname :";
	    if ( !exists ${$this->{weather_area}}{$areaname} && $city =~ /^\d+$/ ) {
		${$this->{weather_area}}{$areaname} = $city;
		open AREA,">>$weather_area_file";
		print AREA "$areaname:$city\n";
		close AREA;
	    }
	}
	     if ( /<td class=\"time left\">(\d+)<\/td>/ ) {
		 $oclock = $1;
	     }
	     if ( /(<td class=\"block top bgcolor\">.*<\/td>)/ ) {
		 my $line = $1;
		 $line =~ s/<td.*?>//g;
		 my @fields = split(/<\/td>/,$line);
		 my $cnt = 0;
		 %fieldname = map { $_, $cnt++ } @fields;
	     }
	     if ( /(<td class=\"block middle\">.*<\/td>)/ ) {
		 my $line = $1;
		 $line =~ s/<td.*?>//g;
		 my @fields = split(/<\/td>/,$line);
		 if ( $fields[0] =~ /^[\d\.\-]+$/ ) {
		     $got = 1;
		     $time = $oclock;
		     $temper = $fields[ $fieldname{'����'} ] if exists( $fieldname{'����'} );
		     $rainfall = $fields[ $fieldname{'�߿���'} ] if  exists( $fieldname{'�߿���'} );
		     $dirwind = $fields[ $fieldname{'����'} ] if exists( $fieldname{'����'} );
		     $windspeed = $fields[ $fieldname{'��®'} ] if exists( $fieldname{'��®'} );
		     $sunlight = $fields[ $fieldname{'���Ȼ���'} ] if exists( $fieldname{'���Ȼ���'} ); 
		     $humidity = $fields[ $fieldname{'����'} ] if exists( $fieldname{'����'} );
		     $pressure = $fields[ $fieldname{'����'} ] if exists( $fieldname{'����'} );
		     $snow = $fields[ $fieldname{'���㿼'} ] if exists( $fieldname{'���㿼'} );
		 }
	     }
	 }
	if ( $got ) {
	    $rainfall .= 'mm' if ( $rainfall ne '̵��' );
	    my $outtext = "$time����";
	    $outtext .= " ������$temper�� " if exists( $fieldname{'����'} ) && $temper !~ /nbsp/;
	    $outtext .= " �߿���:$rainfall "if exists( $fieldname{'�߿���'} ) && $rainfall !~ /nbsp/;
	    $outtext .= " ������$dirwind "if exists( $fieldname{'����'} ) && $dirwind !~ /nbsp/ ;
	    $outtext .= " ��®${windspeed}m/s " if exists( $fieldname{'��®'} ) && $windspeed !~ /nbsp/;
	    $outtext .= " ���Ȼ���${sunlight}h " if exists( $fieldname{'���Ȼ���'} ) && $sunlight !~ /nbsp/;
	    $outtext .= " ����${humidity}% " if exists( $fieldname{'����'} ) && $humidity !~ /nbsp/;
	    $outtext .= " ����${pressure}hPa " if exists( $fieldname{'����'} ) && $pressure !~ /nbsp/;
	    $outtext .= " ����${snow}cm " if exists( $fieldname{'���㿼'} ) && $snow !~ /nbsp/;
	    $outtext .= "\n";
	    $outstr .= $outtext;
	} else {
	    $outstr = "ŷ�����������Ǥ��ޤ���Ǥ�����";
	}
	
	return $outstr;
}

1;
