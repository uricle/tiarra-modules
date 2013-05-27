# -*- mode: Perl -*-
package Tools::dollar;
use lib "$ENV{HOME}/perllib";
use strict;
use base qw(Module);
use Module::Use qw(Auto::Utils);
use Auto::Utils;
use Mask;
use Multicast;
use Jcode;
use Encode;
use Unicode::Japanese;
use LWP::UserAgent;
use LWP::Simple;
use HTTP::Request::Common qw(GET);

# --------------------------------------
sub new {
  my $class = shift;
  my $this = $class->SUPER::new;
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
    if ( $param1 =~ /^(.*?)いくら(\?|？)(?:＞|>)(?:$my_nick|$my_alias)$/ && 
	 Mask::match_deep([$this->config->channel('all')],$msg->param(0)) ) {
      $reply_msg = get_yen( $this, $1 );
    }
    if ( $reply_msg ne "" ) {
      $reply_anywhere->(jcode($reply_msg)->jis);
    }
  }
  return @result;
}
sub get_yen {
  my ($this,$yen) = @_;
  my $ua = LWP::UserAgent->new;
  #$ua->agent("Mozilla/5.0 (Windows; U; Windows NT 5.1; ja; rv:1.9.2.8) Gecko/20100722 Firefox/3.6.8 (.NET CLR 3.5.30729)");
  $ua->agent("Mozilla/5.0 (Windows NT 6.1; WOW64; rv:9.0.1) Gecko/20100101 Firefox/9.0.1");
  $ua->timeout(30);
  # proxyがあるなら適用
  my $my_proxy = $this->config->proxy;
  if ( $my_proxy ne "" ) {
    $ua->proxy(['http','ftp'], $my_proxy);
  }
  # request
  $yen = Unicode::Japanese->new($yen, 'euc')->utf8;
  $yen =~ s/([^\w ])/'%'.unpack('H2', $1)/eg;
  my $requesturl = "http://www.google.co.jp/ig/calculator?ie=utf8&oe=utf8&hl=ja&q=$yen";
  my $res = $ua->request(GET $requesturl);
  my $content = $res->decoded_content;
  my $text = Unicode::Japanese->new($content,'utf8')->euc;
  $text =~ s/&\#160;//g;
  $text =~ s/&\#215;/x/g;
  $text =~ s/<font.+?>\s<\/font>//g;
  my $yen = "取得に失敗";
  # {lhs: "1米ドル",rhs: "88.3470271 円",error: "",icc: true}
  $text =~ s/(?:^\{)|(\}\$)//g;
  if ($text =~ /lhs:\s+\"(.*?)\".*?rhs:\s+\"(.*?)\".*?error:\s+\"(.*?)\"/ ) {
    my ($query,$answer,$error) = ($1,$2,$3);
    if ( $answer ne "" ) {
      $yen = "$query = $answer";
    } elsif ( $error ne "" ) {
      $yen = $yen . "(error:$error)";
    }
  }
#   open my $TEST, ">googleout.html";
#   print $TEST $text;
#   close ($TEST);
  return $yen;
}
1;
