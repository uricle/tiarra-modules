# -*- mode: CPerl -*-
# --------------------------------------
# qbot Plugin: exciteenja
# Author: qux
# Version:
# --------------------------------------
# Description: google溯条に奶します。
# --------------------------------------

package Tools::enjagoogle;

use strict;
use base qw(Module);
use Module::Use qw(Auto::Utils);
use Auto::Utils;
use Mask;
use Multicast;
# --------------------------------------
use Jcode;
use LWP::UserAgent;
use HTTP::Request::Common qw(POST);
use HTML::Entities;
# --------------------------------------
sub start {
    1;
}
sub message_arrived {
    my ($this,$msg,$sender) = @_;
    my @result = ($msg);
    # PRIVMSGか々
    if ($msg->command eq 'PRIVMSG') {
		my $my_nick;
		if ($sender->isa('IrcIO::Client')) {
			$my_nick = $msg->param(0);
		} else {
			$my_nick = $sender->current_nick;
		}
		my ($get_ch_name,undef,undef,$reply_anywhere)
		  = Auto::Utils::generate_reply_closures($msg,$sender,\@result);
		# replyに肋年されたものの面から、办米しているものがあれば券咐。
		# 办米にはMask::matchを脱いる。
		my $param1 = jcode($msg->param(1))->euc;
		# _decode_entities($param1, { reg => '(R)' });
		my $reply_msg;
		my $reply_excite;
		my $reply_bing;
		my $my_alias = jcode($this->config->nick)->euc;
		if ( $param1 =~ /^(?:下条|毖下)\s*(.*)(?:′|>)(?:$my_nick|$my_alias)$/ ) {
			$reply_msg = google_translate( "", $1, 'auto','ja' );
			$reply_excite = excite_translate( "", $1, 'ENJA' );
		}
		if ( $param1 =~ /^(?:毖条|下毖)\s*(.*)(?:′|>)(?:$my_nick|$my_alias)$/ ) {
			$reply_msg = google_translate( "", $1, 'ja','en' );
	        $reply_excite = excite_translate( "", $1, 'JAEN' );
		}
		if ( $param1 =~ /^(?:施条|下施)\s*(.*)(?:′|>)(?:$my_nick|$my_alias)$/ ) {
			$reply_msg = google_translate( "", $1, 'ja','fr' );
			$reply_excite = "";
		}
		if ( $param1 =~ /^(?:迫条|下迫)\s*(.*)(?:′|>)(?:$my_nick|$my_alias)$/ ) {
			$reply_msg = google_translate( "", $1, 'ja','de' );
			$reply_excite = "";
		}
		if ( $param1 =~ /^(?:面下)\s*(.*)(?:′|>)(?:$my_nick|$my_alias)$/ ) {
			$reply_msg = google_translate( "", $1, 'zh-TW','ja' );
			$reply_excite = "";
		}
		if ( $param1 =~ /^(?:面条|下面)\s*(.*)(?:′|>)(?:$my_nick|$my_alias)$/ ) {
			$reply_msg = google_translate( "", $1, 'ja','zh-TW' );
			$reply_excite = "";
		}
		if ( $reply_msg ne "" ) {
			decode_entities($reply_msg);
			#_decode_entities($reply_msg, { reg => '(R)' } );
		    $reply_msg = "google: ".$reply_msg;
			$reply_anywhere->(jcode($reply_msg)->jis);
		}
		if ( $reply_excite ne "" ) {
			decode_entities($reply_excite);
		    $reply_excite = "excite: ".$reply_excite;
			$reply_anywhere->(jcode($reply_excite)->jis);
		}
		if ( $reply_bing ne "" ) {
		  decode_entities($reply_bing);
		  $reply_bing = "bing: ".$reply_bing;
		  $reply_anywhere->(jcode($reply_bing)->jis);
		}
	}
    return @result;
}

# --------------------------------------
sub google_translate {
    my ($chan,$string,$sl,$tl) = @_;
    my $ua = LWP::UserAgent->new;
    $ua->agent("Mozilla/4.0 (compatible; Translate Bot;)");
    $ua->timeout(10);
    my $requesturl = 'http://translate.google.co.jp/';
    my %formdata = ('text' => jcode($string)->utf8,
					'ie' => 'UTF-8',
					'oe' => 'UTF-8',
					'sl' => $sl,
					'tl' => $tl,
				   );
    my $request  = POST($requesturl, [%formdata]);
    my $res = $ua->request($request);
    my $preface =  '<span id=result_box[^>]+>';
    my $anteface = '</span>';
    my $data = jcode($res->content)->euc;
    $data =~ /$preface(.*?)$anteface/mis;
    my $reply = jcode($1)->euc;
    $reply =~ s/<[^<]+>//g;
    $reply =~ s/[\r\n]//g;
    $reply =~ s/\&\#\d+?;//g;
    if ( $reply eq "" ) {
      $reply = "溯条ができなかったようです。(AR)";
    }
    return $reply;
    # &qbot::NOTICE( $chan, $1 );
}
# --------------------------------------
sub excite_translate {
    my ($chan,$string,$direction) = @_;
    my $ua = LWP::UserAgent->new;
    $ua->agent("Mozilla/5.0 (Windows; U; Windows NT 5.2; ja; rv:1.9.0.8) Gecko/2009032609 Firefox/3.0.8");
    $ua->timeout(10);
    my $requesturl = 'http://www.excite.co.jp/world/english/';
    my %formdata = (
#		    '_qf__formTrans' => '',
#                    '_token' => '0b65ee1ef3739',
#                    'count_translation' => '0',
#                    're_translation' => '',
		    'before' => jcode($string)->utf8,
#		    'after' => '',
		    'wb_lp' => $direction,
#		    'swb_lp' => '',
#		    'start' => '溯条',
		    );
    my $request  = POST($requesturl, [%formdata]);
    my $res = $ua->request($request);
    my $preface =  '<textarea id="after"[^>]*?>';
    my $anteface = '</textarea>';
    my $data = jcode($res->as_string)->euc;
	# for debug
#  	open my $FH, ">excite.txt";
#  	print $FH "hogehoge\n";
#  	print $FH $res->error_as_HTML();
#  	print $FH $res->is_redirect;
#         #print $FH $res->as_string;
#         print $FH $data;
#  	close $FH;
    $data =~ /$preface(.*?)$anteface/mis;
	my $reply = $1;
	$reply =~ s/[\r\n]//g;
    $reply =~ s/\&\#\d+?;//g;
    return $reply;
    # &qbot::NOTICE( $chan, $1 );
}
# --------------------------------------
sub bing_translate {
    my ($chan,$string,$direction) = @_;
    my $ua = LWP::UserAgent->new;
    $ua->agent("Mozilla/5.0 (Windows; U; Windows NT 5.2; ja; rv:1.9.0.8) Gecko/2009032609 Firefox/3.0.8");
    $ua->timeout(10);
    my $requesturl = 'http://www.microsofttranslator.com/';
    my %formdata = (
#		    '_qf__formTrans' => '',
#                    '_token' => '0b65ee1ef3739',
#                    'count_translation' => '0',
#                    're_translation' => '',
		    'before' => jcode($string)->utf8,
#		    'after' => '',
		    'wb_lp' => $direction,
#		    'swb_lp' => '',
#		    'start' => '溯条',
		    );
    my $request  = POST($requesturl, [%formdata]);
    my $res = $ua->request($request);
    my $preface =  '<textarea id="after"[^>]*?>';
    my $anteface = '</textarea>';
    my $data = jcode($res->as_string)->euc;
	# for debug
#  	open my $FH, ">excite.txt";
#  	print $FH "hogehoge\n";
#  	print $FH $res->error_as_HTML();
#  	print $FH $res->is_redirect;
#         #print $FH $res->as_string;
#         print $FH $data;
#  	close $FH;
    $data =~ /$preface(.*?)$anteface/mis;
	my $reply = $1;
	$reply =~ s/[\r\n]//g;
    return $reply;
    # &qbot::NOTICE( $chan, $1 );
}
# --------------------------------------
1;
