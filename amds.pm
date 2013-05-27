# -*- mode: Perl -*-
# --------------------------------------
# Author: qux
# --------------------------------------
# Description: アメダスの返事をします
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
    
    # サーバーからのメッセージか？
#      if ($sender->isa('IrcIO::Server')) {
#      } else {
# 	 my $my_nick = $sender->current_nick;
#      }
    # PRIVMSGか？
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
	if ( $param1 =~ /^(?:アメダス)\s*(.*)(?:＞|>)(?:$my_nick|$my_alias)$/ && 
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
    my ($sec,$min,$hour,$mday,$mon,$year) = localtime(time); # 今日の日付をもらう。
    $year += 1900;		# もらえる年は1900年少ないのです。
    $mon += 1;			# 月も 1 少ないのです。
    if ( $hour eq 0 ) {
		$baseurl = $weather_news_base_yesterday;
		$hour = 24;
    } else {
	$baseurl = $weather_news_base;
    }
    my $fullurl;
    if ( $city =~ /^\d+$/ ) {
	# エリアコード指定
	$fullurl = $baseurl . $city . '.html';
    } else {
	# 地名指定
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
    my %fieldname = ( '気温' => -1,
		      '降水量' => -1,
		      '風向' => -1,
		      '風速' => -1,
		      '日照時間' => -1,
		      '湿度' => -1,
		      '気圧' => -1 );
#     <tr>
# 	<td class="time top_left">時刻</td>
# 	<td class="block top bgcolor">気温</td><td class="block top bgcolor">降水量</td><td class="block top bgcolor">風向</td><td class="block top bgcolor">風速</td><td class="block top bgcolor">日照時間</td><td class="block top bgcolor">湿度</td><td class="block top bgcolor">気圧</td>
#     </tr>
#     <tr>
#         <td class="time left">時</td>
# 	<td class="block middle bgcolor">℃</td><td class="block middle bgcolor">mm</td><td class="block middle bgcolor">16方位</td><td class="block middle bgcolor">m/s</td><td class="block middle bgcolor">h</td><td class="block middle bgcolor">%</td><td class="block middle bgcolor">hPa</td>
#     </tr>
#     <tr>
# 	<td class="time left">1</td>
# 	<td class="block middle">12.1</td><td class="block middle">0.0</td><td class="block middle">南南東</td><td class="block middle">1</td><td class="block middle">&nbsp;</td><td class="block middle">80</td><td class="block middle">1012.9</td>
#     </tr>
    my $oclock = 0;
    my $outstr = "";
    my ($time,$temper,$rainfall,$dirwind,$windspeed,$humidity,$sunlight,$pressure,$snow);
    my $got = 0;
    my ($year,$month,$day);
    foreach ( split/\n/, $text ) {
	chomp;
	if ( /<title>(\d+)年(\d+)月(\d+)日(.*?)\(/ ) {
	    $year = $1;
	    $month = $2;
	    $day = $3;
	    my $areaname = $4;
	    $areaname =~ s/　//g;
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
		     $temper = $fields[ $fieldname{'気温'} ] if exists( $fieldname{'気温'} );
		     $rainfall = $fields[ $fieldname{'降水量'} ] if  exists( $fieldname{'降水量'} );
		     $dirwind = $fields[ $fieldname{'風向'} ] if exists( $fieldname{'風向'} );
		     $windspeed = $fields[ $fieldname{'風速'} ] if exists( $fieldname{'風速'} );
		     $sunlight = $fields[ $fieldname{'日照時間'} ] if exists( $fieldname{'日照時間'} ); 
		     $humidity = $fields[ $fieldname{'湿度'} ] if exists( $fieldname{'湿度'} );
		     $pressure = $fields[ $fieldname{'気圧'} ] if exists( $fieldname{'気圧'} );
		     $snow = $fields[ $fieldname{'積雪深'} ] if exists( $fieldname{'積雪深'} );
		 }
	     }
	 }
	if ( $got ) {
	    $rainfall .= 'mm' if ( $rainfall ne '無し' );
	    my $outtext = "$time時の";
	    $outtext .= " 気温は$temper度 " if exists( $fieldname{'気温'} ) && $temper !~ /nbsp/;
	    $outtext .= " 降水量:$rainfall "if exists( $fieldname{'降水量'} ) && $rainfall !~ /nbsp/;
	    $outtext .= " 風向は$dirwind "if exists( $fieldname{'風向'} ) && $dirwind !~ /nbsp/ ;
	    $outtext .= " 風速${windspeed}m/s " if exists( $fieldname{'風速'} ) && $windspeed !~ /nbsp/;
	    $outtext .= " 日照時間${sunlight}h " if exists( $fieldname{'日照時間'} ) && $sunlight !~ /nbsp/;
	    $outtext .= " 湿度${humidity}% " if exists( $fieldname{'湿度'} ) && $humidity !~ /nbsp/;
	    $outtext .= " 気圧${pressure}hPa " if exists( $fieldname{'気圧'} ) && $pressure !~ /nbsp/;
	    $outtext .= " 積雪${snow}cm " if exists( $fieldname{'積雪深'} ) && $snow !~ /nbsp/;
	    $outtext .= "\n";
	    $outstr .= $outtext;
	} else {
	    $outstr = "天気情報を取得できませんでした。";
	}
	
	return $outstr;
}

1;
