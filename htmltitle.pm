# -*- mode: CPerl -*-
package Tools::htmltitle;

use lib "$ENV{HOME}/perllib";
# --------------------------------------
# FetchTitleを色々参考に
# + Tools::htmltitle {
#     channel: #hoge@hoge:*.jp
#     ignoreURI: hoge.co.jp
#     proxy:
#     assocID:
#     extra: name1 name2 ...
#     extra-name1 {
#       url:        http://www.example.com/*
#       recv_limit: 10*1024
#       extract:    re:<div id="title">(.*?)</div>
#     }
#    }
#  }
# Auto::FetchTitle { ... } での設定
# + Auto::FetchTitle {
#     plugins {
#       ExtractHeading {
#         extra: name1 name2 ...
#         extra-name1 {
#           url:        http://www.example.com/*
#           recv_limit: 10*1024
#           extract:    re:<div id="title">(.*?)</div>
#         }
#       }
#    }
#  }
# --------------------------------------

use strict;
use base qw(Module);
use Module::Use qw(Auto::Utils);
use Auto::Utils;
use Mask;
use Multicast;
use Compress::Zlib;
# --------------------------------------
use Jcode;
use Encode;
use LWP::UserAgent;
use HTTP::Request::Common;# qw(GET HEAD);
use HTML::HeadParser;
use File::Temp qw(tempfile);
use Unicode::Japanese;
use Unicode::Normalize;
use NKF;
use IO::Socket::SSL;
use HTTP::Message;
# --------------------------------------
sub new {
	my $class = shift;
	my $this = $class->SUPER::new;
	$this->{extra} = undef;
	$this->{channels} = ();
	$this->{ignoreURI} = ();
	$this->{assocID} = ();
	$this->{oldassoc} = "";
	$this->_init;
	@{$this->{channels}} = $this->config->channel('all');
	$this->{localname} = $this->config->localname;
	$this->{ua} = $this->config->ua;
	$this->{proxy} + $this->config->proxy;
	return $this;
}

sub _init {
    my $this = shift;
	my @config;
	$this->{extra} = \@config;
    foreach ( $this->config->channel('all')) {
		s/(,)\s+/$1/g; # カンマの直後にスペースがあった場合、削除する
		s/\s+/,/g;
		my @chlist = split(/,/,$_);
		foreach (@chlist) {
			push @{$this->{channels}}, $_;
		}
    }
    foreach ( $this->config->ignoreURI('all')) {
		s/(,)\s+/$1/g; # カンマの直後にスペースがあった場合、削除する
		s/\s+/,/g;
		my @ignoreList = split(/,/,$_);
		foreach (@ignoreList) {
			push @{$this->{ignoreURI}}, $_;
		}
    }
    foreach ( $this->config->assocID('all')) {
		s/(,)\s+/$1/g; # カンマの直後にスペースがあった場合、削除する
		s/\s+/,/g;
		my @assocID = split(/,/,$_);
		foreach (@assocID) {
			push @{$this->{assocID}}, $_;
		}
    }
#	$this->{NoticeReceived} = 0;
#	$this->{timer} = undef;
	# ExtractFetch 互換オプション取り込み
	foreach my $token (map{split(' ', $_)}$this->config->extra('all')) {
		#$this->notice("extra: $token");
		my $name	= "extra-$token";
		my $block = $this->config->$name;
		if( !$block ) {
			#$this->notice("no such extra config: $name");
			next;
		}
		if( !ref($block) ) {
			my $literal = $block;
			$block = Configuration::Block->new($name);
			$block->extract($literal);
		}
		my $has_param;
		my $config = {};
		$config->{name} = $name;
		$config->{url}  = $block->url;
		if( !$config->{url} ) {
			#$this->notice("no url on $name");
			next;
		}
		if( my $recv_limit = $block->get('recv_limit') )  {
			while( $recv_limit =~ s/^\s*(\d+)\*(\d+)/$1*$2/e )
			  {
			  }
			$config->{recv_limit} = $recv_limit;
			$has_param = 1;
		}
		my @extract;
		foreach my $line ($block->extract('all')) {
			$has_param ||= 1;
			my $type;
			my $value = $line;
			if( $value =~ s/^(\w+)(:\s*|\s+)// ) {
				$type = $1;
			}
			$type ||= 're';
			if( $type eq 're' )  {
				$value =~ s{^/(.*)/(\w*)\z/}{(?$2:$1)};
				my $re = eval{
					local($SIG{__DIE__}) = 'DEFAULT';
					qr/$value/s;
				};
				if( my $err = $@ ) {
					chomp $err;
					#$this->notice("invalid regexp $re on $name, $err");
					next;
				}
				push(@extract, $re);
			}else {
				#$this->notice("unknown extract type $type on $name");
				next;
            }
		}
		if( @extract ) {
			$config->{extract} = @extract==1 ? $extract[0] : \@extract;
		}
		if( keys %$config==1 ) {
			#$this->notice("no config on $name");
			next;
		}
		push(@config, $config);
	}
}

# -----------------------------------------------------------------------------
# $this->_config().
# config for extract-heading.
#
sub _config
  {
  my $this = shift;
  my $config =
    [
     @{$this->{extra}},
     {
      # 3a. nikkei.
      url        => 'http://www.nikkei.co.jp/*',
      recv_limit => 16*1024,
      extract => [
                  qr{<META NAME="TITLE" CONTENT="(.*?)">}s,
                  qr{<h3 class="topNews-ttl3">(.*?)</h3>}s,
                 ],
      remove => qr/^NIKKEI NET：/,
	  title => '[日経]',
	  # timeout => 0,
    },
     {
      # 3b. nikkei.
      url        => 'http://release.nikkei.co.jp/*',
      recv_limit => 18*1024,
      extract => qr{<h1 id="heading" class="heading">(.*)</h1>}s,
     },
     {
      # 7. trac changeset.
      url        => '*/changeset/*',
      extract    => qr{<dd class="message" id="searchable"><p>(.*?)</p>}s,
      recv_limit => 8*1024,
    },
#  〜のRSS 等も一緒に拾われたのでコメントアウト
#     {
#       # 10. sanspo.
#       url        => 'http://www.sanspo.com/*',
#       recv_limit => 5*1024,
#       extract    => qr{<h2>(.*?)</h2>}s,
#     },
    {
      # 11. sakura.
      url        => 'http://www.sakura.ad.jp/news/archives/*',
      recv_limit => 10*1024,
      extract    => qr{<h3 class="newstitle">(.*?)</h3>}s,
    },
    {
      # 12. viewvc.
      url        => '*/viewcvs.cgi/*',
      extract    => qr{<pre class="vc_log">(.*?)</pre>}s,
    },
     {
      # 13. toshiba.
      url        => 'http://www.toshiba.co.jp/about/press/*',
      extract    => qr{<font size=\+2><b>(.*?)</b></font>}s,
     },
     {
      # 27. nintendo.
      url        => 're:https?://www.nintendo.co.jp/corporate/release/.*',
      extract    => qr{<h1 id="nr_title">(.*?)</h1>}sio,
      title => 'nintendo',
      remove => qr{\s{2,}}sio,
     },
     # bnn-s
     {
      url => 'http://www.bnn-s.com/*',
      extract => qr{<div\s+class=\"detailTitle\">([^<]+)\s*<\/}s,
      title => '[BNN]',
     },
     # zakzak
     {
      url     => 'http://www.zakzak.co.jp/*',
      extract => [
		  qr{<!--midashi-->([^<]+)}sio,
		  qr{<font\s+class=\"kijimidashi\"\s+size=\"\d+\">(.+?)<\/font}sio,
		  qr{<div class="titleArea">(.*?)</div>}mio,
		 ],
      remove  => qr{<[^>]+?>},
     },
	 # doshin
# 	 {
# 	  url     => 'http://www.hokkaido-np.co.jp/*',
# 	  extract => qr{(?:class=\"i-caption\s+i-genre-title\">([^<]+)<.*?)?<h2.*?>([^<]+?)<}sio,
# 	  title => '[道新]',
# 	  separator => ':',
# 	 },
	 # moepic
	 {
	  url     => 'http://moepic.com/top/news_detail.php?*',
	  extract => qr{<td>(.*?)<br>}s,
	  remove  => qr{<span.*?>.*?<\/span>}ios,
	  title => '[MoE Official]',
	 },
	 # saga shinbun
	 {
	  url => 'http://www.saga-s.co.jp/view.php?*',
	  extract => qr{<span\s+class=\"pbCornerNewsArticleMainTitle\">(.+?)<}sio,
	  title => '[佐賀新聞]',
	 },
	 # biglobe news
	 {
	  url => 'http://news.biglobe.ne.jp/*',
	  extract => qr{<h4\s+class=\"ch15\">(.+?)<\/}sio,
	  title => '[biglobe news]',
	 },
	 # futaba
	 {
	  url     => 'http://*.2chan.net/*',
	  extract => qr{<title>(.*?)<\/title>.*?<blockquote>(.*?)<\/blockquote>.*?<blockquote>(.*?)<\/blockquote>},
	  separator => '：',
	 },
	 # 2ch
	 {
	  url     => 'http://*.2ch.net/*',
	  extract => qr{<h1.*?>(.*?)<\/h1>.*?<dd>(.*?)<br><br>},
	  separator => '：',
	 },
	 # impress test
# 	 {
# 	  url  => 'http://pc.watch.impress.co.jp/docs/*',
# 	  extract => qr{記事タイトル\s*-->\s*<h3>(.+?)</h3>\s*<!--\s/記事タイトル}mio,
# 	 },
	 # mh-frontier.jp
	 {
	  url => 'http://*.mh-frontier.jp/information/news/*',
	  extract => qr{<div\s+class="newstitle_area">.+<td\s+valign="top"\salign="left"\s.+?>(.+?)</td>}mio,
	  remove => qr{<br>},
	 },
     {
	  # NTT-X
      url     => 'http://nttxstore.jp/*',
	  extract => [
				  qr{<h1 class="title">(.*?)</h1>.*?<!--([\\\d,]+?)-->.*?<li class="place_coupon">(.*?)</li>}mio,
				  qr{<h1 class="title">(.*?)</h1>.*?<!--([\\\d,]+?)-->}mio,
				 ],
	 },
	 # twitter
     {
	  url     => 're:https?://(?:mobile.)?twitter.com/.*',
	  #extract => qr{<p class="js-tweet-text.*?">(.*?)</p>}sio,
# 	  extract => [
# 		      qr{<p class="js-tweet-text .*?">(.*?)</p>}sio,
# 		      qr{<div class="tweet-text js-tweet-text">(.*?)</div>}sio,
# 		     ],
#	  extract => qr{<div class="tweet permalink-tweet.*?".*?>.*?<p class="js-tweet-text.*?">(.*?)</p>}sio,
	  extract => [
#		      qr{<div class="tweet permalink-tweet.*?<p class="js-tweet-text .*?">(.*?)</p>}sio,
		      qr{<p class="TweetTextSize\s*TweetTextSize.*?>(.*?)</p>}sio,
                 qr{<p class="js-tweet-text .*?">(.*?)</p>}sio,
                     ],
	  title => 'Twitter',
	 },
     {
      url => 're:https?://mstdn.jp\/.*',
      extract => [
		  qr{<meta content='([^<>]+?)'\sproperty='og:description'}sio,
		  qr{div class='status__content p\-name emojify'>(.*?)</div>}sio
		 ],
      title => 'mstdn',
     },
	 # aion
	 {
	  url     => 'http://aion.plaync.jp/board/*',
	  extract => qr{<div class="subject">(?:<img.+?/>)?(.+?)</div>}sio,
	 },
	 # playstation Home market
	 {
	  url     => 'https://playstationhome.jp/market/*',
	  extract => qr{<h2>(.+?)</h2>}mio,
	 },
	 # twitpic
	 {
	  url     => 'http://twitpic.com/*',
	  #extract => qr{<div id="view-photo-caption">(.+?)</div>}sio,
	  extract => qr{<meta property="og:title" content="(.+?)"/>}sio,
	  title   => 'Twitpic',
	 },
	 # Do-mu
	 {
	  url     => 'http://www.at-mac.com/*/shop/product/*',
	  extract => qr{<meta name="description" content="(.+?)">}sio,
	  title   => 'Do-夢',
	 },
	 {
	  # itunes.apple.com
	  url     => 'https://itunes.apple.com/*',
	  extract => qr{<h1>(.*?)</h1>.*?<div class="price">(.*?)</div>.*?<span class="app-requirements">条件.*?</span>(.*?)</p>}sio,
	  separator => ' ',
	  remove => qr{が必要},
	  title  => 'iTunes Store',
	 },
	 {
	  url => 'http://www.tdb.co.jp/tosan/syosai/*',
	  extract => qr{<span class="bold">(.*?)</span>}sio,
	 },
     # Instagram
     {
      url     => 'http://instagr.am/p/*',
      extract => qr{<div class="caption">(.*?)</div>}sio,
     },
     {
      url     => 'https://www.instagram.com/p/*',
      extract => qr{meta content="(.*?)" name}sio,
     },
     # dqx hiroba
     {
      url    => 'http://hiroba.dqx.jp/sc/forum/*',
      extract => qr{<h2 class="threadTitle">(.*?)</h2>(?:.*plus">(\d+)</td>.+minus">(\d+)</td>.+even">(\d+)</td>)?}sio,
      separator => ':',
      title => 'DQX 冒険者の広場',
     },
     # dqx news
     {
      url    => 'http://hiroba.dqx.jp/sc/news/*',
      extract => qr{<h3 class="iconTitle">(.*?)</h3>},
     },
     # 47news FN
     {
      url   => 'http://www.47news.jp/FN/*',
      extract => qr{<meta name="description" content="(.*?)"\s*/>}sio,
     },
     # youtube
     {
      url   => 'https://www.youtube.com/watch*',
      extract => qr{document.title\s*=\s*\"(.+?)(?:\s+-\s+YouTube)?\"}io,
     },
    ];
  $config;
}

# search engine
sub search_config {
	my $config =
	  [
	   {
		url => qr{http://.+?.google.(?:com|co.jp)/.*?q=([^&]+)}io,
		title => 'Google',
	   },
	   {
		url => qr{http://.+?yahoo.co.jp/search\?p=([^&]+)}io,
		title => 'Yahoo Search',
	   },
	   {
		url => qr{http://.+?goo.ne.jp/.*?MT=([^&]+)}io,
		title => 'Goo',
	   },
	   {
		url => qr{http://.+?biglobe.ne.jp/.+?search.+?q=([^&]+)}io,
		title => 'biglobe search',
	   },
	   ];
	$config;
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
      # replyに設定されたものの中から、一致しているものがあれば発言。
      # 一致にはMask::matchを用いる。
      # 	    foreach ($this->config->reply('all')) {
      # 		my ($mask,$reply_msg) = m/^(.+?)\s+(.+)$/;
      # 		if (Mask::match($mask,$msg->param(1))) {
      # 		    # 一致していた。
      # 		    $reply_anywhere->($reply_msg);
      # 		}
      # 	    }
      my $chmatch = 0;
      #print STDERR "param0 " . $msg->param(0) . "\n";
      # 		foreach ( @{$this->{channels}} ) {
      # 		  #if ( $msg->param(0) eq $_ ) {
      # 		  if ( $msg->param(0) =~ /^$_$/i ) {
      # 		    $chmatch = 1;
      # 		    last;
      # 		  }
      # 		}
      $chmatch = Mask::match_deep([@{$this->{channels}}],$msg->param(0));
      if ( $chmatch ) {
	#my $param1 = jcode($msg->param(1))->euc;
	my $param1 = $msg->param(1);#nkf("-ex", $msg->param(1));
	#print STDERR "param1 $param1\n";
	my $reply_msg;
	if ( $param1 =~ /(https?:\/\/[-_.!~*\'()a-zA-Z0-9;\/?:\@&=+\$,%\#]+)/o ) {
	  #print STDERR "fetch:$param1\n";
	  $reply_msg = title_get( $this, $1 );
	  #print STDERR "$reply_msg\n";
	  $this->{NoticeReceived} = 0;
	}
	if ( $reply_msg ne "" ) {
	  my %entities = (
			  'nbsp' => ' ',
			  'iexcl' => 'i',
			  # 'cent' => 'c', # cent sign
			  # 'pound' => 'pound',	# pound sign
			  # 'curren' => '',	# currency sign
			  # 'yen' => '\\', # yen sign
			  # 'brvbar' => '|', # broken vertical ber
			  # 'sect' => 'S', # section sign
			  # 'uml' => '..', # spacing diaeresis
			  'copy' => '(C)', # copyright sign
			  # 'ordf' => 'a', # feminine ordinal indicator
			  'laquo' => '<<', # eft pointing guillemet
			  # 'not' => 'not',	# not sign
			  # 'shy' => '-', # soft hyphen
			  'reg' => '(R)',	# registered sign
			  # 'macr' => '~', # macron
			  # 'deg' => '', # degree sign
			  'raquo' => '>>',
			  'amp' => '&',
			  'quot' => '"',  # quote
			  'ldquo' => '「',
			  'rdquo' => '」',
			  'gt' => '>',
			  'lt' => '<',
			 );
	  foreach my $entity (keys %entities) {
	    $reply_msg =~ s/&$entity;/$entities{$entity}/g;
	  }
	  my $ascii = '[\x00-\x7f]';
	  my $twoBytes = '[\x8E\xA1-\xFE][\xA1-\xFE]';
	  my $threeBytes = '\x8F[\xA1-\xFE][\xA1-\xFE]';
	  my @chars = $reply_msg =~ /$ascii|$twoBytes|$threeBytes/og;
	  #my @reply_array = $reply_msg =~ /.{1,220}/g;
	  my @reply_array;
	  my $cnt = 0;
	  my $pos = 0;
	  foreach (@chars) {
	    if ( $_ eq "\n" ) {
	      $cnt = 0;
	      $pos++; next;
	    }
	    $reply_array[$pos] .= $_;
	    $cnt += 3 if ( /$threeBytes/ );
	    $cnt += 2 if ( /$twoBytes/ );
	    $cnt += 1 if ( /$ascii/ );
	    if ( $cnt >= 220 ) {
	      $cnt = 0;
	      $pos++;
	    }
	  }
	  $reply_msg = join("\n", @reply_array);
	  #$reply_msg = substr($reply_msg, 0, 220);
	  #$reply_anywhere->(jcode($reply_msg,'euc-jp')->jis);
	  $reply_anywhere->($_) for split("\n", nkf("-E -wx",$reply_msg));
	}
      }
    }
    return @result;
}

# title get main
sub title_get {
    my ($this, $string) = @_;
	# 無視URIに含まれているか
    foreach ( @{$this->{ignoreURI}} ) {
		return undef if ($_ && $string =~ /($_)/i );
    }
	# localhostに変換するべきか
	my $localname = $this->{localname};#$this->config->localname;
	if ( $localname ne "" ) {
		if ( $string =~ m|https?://$localname| ) {
			$string =~ s/$localname/localhost/;
		}
	}
	# UA 作成
    IO::Socket::SSL::set_ctx_defaults( 
     				      SSL_verifycn_scheme => 'none',
    				      SSL_verify_mode => 0,
    				     );
    # IO::Socket::SSL::set_ctx_defaults( 
    #  				      SSL_verifycn_scheme => 'http',
    # 				      SSL_verify_mode => 1,
    # 				     );
    my $ua = LWP::UserAgent->new;
    $ua->ssl_opts(verify_hostname => 0);
    #$ua->agent("Mozilla/4.0 (compatible; HTML title get Bot;)");
	#$ua->agent("lwp-request/0.01");
	#$ua->agent("Mozilla/4.0 (compatible; MSIE 6.0; Windows NT 5.1; SV1; .NET CLR 1.1.4322)");
    #$ua->agent("Mozilla/5.0 (Windows; U; Windows NT 5.1; ja; rv:1.9.2.8) Gecko/20100722 Firefox/3.6.8 (.NET CLR 3.5.30729)");
    #$ua->agent("Mozilla/4.0");
    my $UserAgent = "Mozilla/5.0 (Windows NT 6.1; WOW64; rv:22.0) Gecko/20100101 Firefox/22.0";
    #$UserAgent = $this->config->ua if defined $this->config->ua;
    $UserAgent = $this->{ua} if defined $this->{ua};
    $ua->agent($UserAgent);
    my $accept = HTTP::Message::decodable;
    $ua->default_header('Accept-Encoding' => $accept);
    #print STDERR "'$UserAgent'";
    #$ua->agent("Mozilla/5.0 (Windows NT 6.1; WOW64; rv:22.0) Gecko/20100101 Firefox/22.0 FirePHP/0.7.2");
    $ua->timeout(30);
    $ua->cookie_jar({});
    #print STDERR "UserAgent->new\n";
	# proxyがあるなら適用
    #my $my_proxy = $this->config->proxy;
    my $my_proxy = $this->{proxy};
    if ( $my_proxy ne "" ) {
		$ua->proxy(['http','ftp'], $my_proxy);
    }
    my $requesturl = $string;
	# twitter用特殊
	$requesturl =~ s|https?://(?:mobile.)?(twitter.com)|https://$1|o;
	$requesturl =~ s|(twitter\.com/)\#!/|$1|o;
	# $ret を戻り値とする。空で返せば返事無し
    my $ret;
	#$ret = $requesturl;
	# URLだけでわかるものは先に処理
    $ret ||= WikiPedia_Get( $requesturl );
    $ret ||= SearchEngine_Get( $requesturl );
    if ( $ret ne "" ) {
		return $ret;
    }
	# recv_limit / timeout apply
	my $extract_list = $this->_config();
	foreach my $conf ( @$extract_list ) {
		Mask::match($conf->{url}, $requesturl) or next;
		# recv_limit (byte)
		if ( exists $conf->{recv_limit} ) {
			$ua->max_size( $conf->{recv_limit} );
			#print STDERR "UserAgent->max_size $conf->{recv_limit}\n";
		}
		# timeout (sec)
		if ( exists $conf->{timeout} ) {
			$ua->timeout( $conf->{timeout} );
			#print STDERR "UserAgent->timeout $conf->{timeout}\n";
		}
	}
	# HTTP request
    #my $request  = GET($requesturl);
    #my $res = $ua->request($request);
    #print STDERR "ua->request: $requesturl\n";
    # my $req = HTTP::Request->new('HEAD');
    # $req->uri($requesturl);
    # 	my $res = $ua->request($req);
    my $res = $ua->head($requesturl);
	# $ret = "$requesturl " . $res->content_type . $res->code;
	# content type check
    #print STDERR "content_type: $res->content_type\n";
    # open my $TEMP, ">test.html";
    # my $content = $res->decoded_content;
    # print $TEMP $res->content_type . "\n";
    # print $TEMP $content;
    # close $TEMP;
    if ( $res->content_type =~ /image/io ) {
		my $content_length = $res->content_length;
		$ua->max_size( 64 * 1024 );
		$res = $ua->request(GET $requesturl);
		# イメージ
		my ($fh,$filename) = tempfile( UNLINK => 0 );
		print $fh $res->content;
		close $fh;
		my ( $format, $width, $height ) = &GetImageSize( $filename);
		$ret = "$format (${width}x${height} pixels, ".$content_length." bytes)";
		unlink($filename);
	      } elsif ( $res->content_type =~ /text\/plain/ && $res->code == '500' ) {
		$ret = $res->decoded_content;
		$ret =~ s/[\r\n]/ /g;
    } elsif ( $res->content_type =~ /text\/(?:(?:ht|x)ml|x-web-textile)/o || $res->code == '405') {
      $res = $ua->request(GET $requesturl);
      #$res = $ua->request(GET $requesturl, 'Accept-Encoding' => 'gzip,deflate');
		#print STDERR "retry end\n";
		#$ret = "$requesturl " . $res->content_type . $res->code;
		my $encode = 'auto';
		my $target = '';
#		if ( $res->content =~ /<meta\s+http-equiv=\"content-type\".*?content=\"text\/html;\s*charset\s*=\s*?([^\"]+)\">/mio ) {
		#my $content = $res->content;;
		my $content = $res->decoded_content;
 		# open my $TEMP, ">test.html";
 		# print $TEMP $content;
 		# close $TEMP;
#  		if ( $res->header('Content-Encoding') =~ /^(gzip|deflate)$/ ) {
#  			$content = Compress::Zlib::memGunzip($content);
#  		}
		#print STDERR "check content header ; ".$res->header('Content-Type')."\n";
		my $header = $res->header('Content-Type');
 		if ( $header =~ /.+?\/.+?;\s*charset\s*=\s*([a-zA-Z0-9\-_]+),?/io ) {
		  $target = $1;
		}
# 		if ( $target eq '' && $content =~ /<(\s*meta\s+[^>]*?http-equiv=\"content-type\".+?)>/mio ) {
#             my $metatag = $1;
# 			# (auto/meta http-equiv="content-type" content="text/html; charset=euc-jp" /) 
#             $metatag =~ /content=\".+?\/x?html(?:\+?.*?);\s*charset\s*=\s*?([^\"]+)\"/;
# 			$target = $1;
# 		}
		if ( $target ne '' ) {
			my %encodes = ('euc-jp' => 'eucjp',
						   'shift-jis' => 'cp932',
						   'shift_jis' => 'cp932',
						   'x-sjis' => 'cp932',
						   'cp932' => 'cp932',
						   'ms932' => 'cp932',
						   'iso-2022-jp' => 'jis',
						   'iso_2022_jp' => 'jis',
                           'utf-8' => 'utf8',
						  );
			$target =~ tr/A-Z/a-z/;
			if ( exists $encodes{$target} ) {
				$encode = $encodes{$target};
			}
			$encode = 'sjis' if $encode eq 'cp932';
		}
		my $text = "";
#		if ( $encode ne 'utf8' ) {
#		  $text = Encode::encode('utf8', $content);
#		} else {
		  $text = Encode::encode('utf8', $content);
#		}
      my $decoded = Encode::decode('utf8', $text);
      #if ( checkNFD($decoded) ) {
      $text = Encode::encode('utf8', NFC($decoded));
      #}
		# no-break space
		$text =~ s/&\#160;/ /g;	
		# ucs2 -> utf8
		$text =~ s/&\#13;&\#10;/\n/g;
		$text =~ s/&\#13;/\n/g;
		$text =~ s/&\#10;/\n/g;
		$text =~ s/\n+/\n/g;
		$text =~ s/\n$//;
		$text =~ s/&\#(\d+);/ucs2_utf8(pack("N*",$1))/eg;
		$text =~ s/&\#x([a-fA-F0-9]+);/ucs2_utf8(pack("H*",$1))/eg;
		# delete 0x00 to 0x09, 0x0b to 0x1f
		$text =~ s/[\00-\x09\x0b-\x1f]//g;
		# にょろ
		# 〜を〜の逆向きに変換することで、eucにした時に正しく見えるようにする
		#$text =~ s/\xef\xbd\x9e/\xe3\x80\x9c/g;
		# ダッシュ(U+FF0D)を水平線(U+2015)に
		#$text =~ s/\x{ff0d}/\-/g;
		$text =~ s/\xef\xbc\x8d/\-/g;
		# http://www.ffortune.net/comp/develop/perl/from_to.htm 参照
		$text =~ s/\xe2\x88\x92/\-/g; # SJIS full width hyphen
		#$text =~ s/\xef\xbc\x8d/\xe2\x80\x95/g;
		#$text =~ tr/\x{ff5e}/\x{301c}/;
		# utf8 -> euc
		#Encode::from_to($text, 'utf-8', 'euc-jp');
      #print STDERR "encode cp932\n";
		my $encoded = encode('cp932', decode_utf8($text));
		$text = encode('euc-jp', decode('shift_jis', $encoded));
		#my $encoded = encode('euc-jp', $text);
		#$text = $encoded;
      #print STDERR "Amazon_get\n";
      $ret ||= Mainichi_Get( $this, $requesturl, \$text, $ua );
		$ret ||= Amazon_Get( $this, $requesturl, \$text );
      #print STDERR "generic_get\n";
        $ret ||= generic_title_get($this, $string, \$text);
      #print STDERR "HTMLTITle_get\n";
		$ret ||= HTMLTitle_Get(\$text);
		# open my $DEBUG, ">debug.txt";
		# print $DEBUG $text;
		# close $DEBUG;
		#$ret = "$header:$encode:$ret";
# for debug
		#$ret = $res->content_type . " $ret";
		#$ret = "($encode/$target) " . $ret;
		#$ret = "(" . $res->header('Content-Type') . "/$target) ". $ret;
	} else { #if ( $res->content_type =~ /(?:application|plain|video)/io ) { #/text\/(plain|video)/ ) {
		# 知らないcontent-typeの場合は、それを返事にする
		$ret = $res->content_type;
    }
    #print STDERR "End : $ret\n";
    return $ret;
}
sub GetDecoder {
  my $res = shift;
  my $content_type = $res->headers->header('Content-Type') . "\n";
  my ($charset) = $content_type =~ /charset=([A-Za-z0-9_\-]+)/io;
  $charset ||= 'unknown';
  my $decoder;
  print "$charset\n";
  if ( $charset eq 'unknown' ) {
    my $text = $res->content;
    $decoder = Encode::Guess->guess($text);
} else {
    $decoder = Encode::find_encoding($charset);
  }
  $decoder;
}

sub ucs2_euc
{
    my $text = shift;
    Encode::from_to($text,'UCS-2BE','iso-2022-jp');
    Encode::from_to($text,'iso-2022-jp','euc-jp');
    return $text;
}
sub ucs2_utf8
{
    my $text = shift;
    Encode::from_to($text,'UCS-2BE','utf8');
    return $text;
}
sub ucs2euc
{
    my $text = shift;
#     my $packtext = pack("N", $text);
#     Encode::from_to($packtext,'UCS-2BE','iso-2022-jp');
#     Encode::from_to($packtext,'iso-2022-jp','euc-jp');
    my $packtext = pack("N", $text);
    $packtext = ucs2_euc($packtext);
    return $packtext;
}
sub utf8_to_euc
{
    my $text = shift;
    Encode::from_to($text,'utf8','euc-jp');#iso-2022-jp');
    return $text;
}
# wikipedia 
sub WikiPedia_Get {
	my ($url) = shift;
	if ( $url =~ m|https?://ja.wikipedia.org/wiki/(.*)|io ) {
		my $text = $1;
		$text =~ s/[%\.]([a-fA-F0-9]{2})/pack("C", hex($1))/eg;
		$text = jcode($text,'utf8')->euc;
		return $text . ' - Wikipedia (AR)';
	}
	undef;
}
# search engine
sub SearchEngine_Get {
	my $url = shift;
	my $extract_list = search_config();
	foreach my $conf ( @$extract_list ) {
		my @match = $url =~ $conf->{url};
		@match or next;
		my $text = $match[ 0 ];
		$text =~ s/[%\.]([a-fA-F0-9]{2})/pack("C", hex($1))/eg;
		$text =~ s/\+/ /g;
 		$text = jcode($text)->euc;
		return "$text - " . $conf->{title} . " (AR)";
	}
# 	if ( $url =~ m{http://www.google.(?:com|co.jp)/.*?q=([^&]+)}io ) {
# 		my $text = $1;
# 		$text =~ s/[%\.]([a-fA-F0-9]{2})/pack("C", hex($1))/eg;
# 		$text = jcode($text)->euc;
# 		return $text . ' - Google (AR)';
# 	}
	undef;
}

# mainichi / openid
sub Mainichi_Get {
  my ( $this, $url, $text, $ua) = @_;
  if ($text =~ /input\stype=.+?name="openid\.return_to"\s+value=".+?url=(.+?)"/mi ) {
    my $next = $1;
    $next =~ s/\+/ /g;
    $next =~ s/%([0-9a-fA-F]{2})/pack("H2",$1)/eg;
    $$text = $ua->request(GET $next)->decoded_content;
  }
  undef;
}

# amazon 
sub Amazon_Get {
  my ( $this, $url, $text) = @_;
  #print STDERR "Amazon_Get\n";
  if ( $url =~ m|^https?://www.amazon.co.jp/.*?([4B][A-Z0-9]{9})| ) {
    # 既に埋まっている場合は加工しない
    #return undef if ( $url =~ /-22\W/ );
    my $ASIN = $1;
    my $name;
    #print STDERR "HTMLTitle_get\n";
    $name ||= HTMLTitle_Get($text);
    # print STDERR $name;
    my $assoc = $this->{oldassoc};
    #print STDERR "Choose assoc\n";
    while ( $assoc eq $this->{oldassoc} ) {
      $assoc = @{$this->{assocID}}[ int ( ((rand (($#{$this->{assocID}}+1)<<4)) >> 4)) ];
    }
    #print STDERR "$assoc\n";
    $this->{oldassoc} = $assoc;
    # 頻度チェック
    # 		my $rndex;
    #  		my @ctr;
    #  		for ( my $i = 0; $i < 2000; $i++ ) {
    #  			$ctr[ int ( ((rand (($#{$this->{assocID}}+1)<<4) )>>4) ) ] ++;
    #  		}
    #  		for ( my $i = 0; $i <= $#{$this->{assocID}}; $i++ ) {
    #  			$rndex .= @{$this->{assocID}}[ $i ] . "(" . $ctr[ $i ] . ") ";
    #  		}
    #my $newurl = "http://www.amazon.co.jp/exec/obidos/ASIN/$ASIN/$assoc/ref=nosim/";
    my $newurl = "http://amazon.jp/dp/$ASIN?m=AN1VRQENFRJN5&tag=$assoc";
    #my $newurl = $rndex;
    return "$name ($newurl)";
  }
  undef;
}

# ExtractHeading::filter_response っぽいもの
sub generic_title_get {
  my ($this, $url, $text) = @_;
  my $extract_list = $this->_config();

  my $heading;
  my $overwrite_title = "";
  foreach my $conf (@$extract_list) {
    Mask::match($conf->{url}, $url) or next;
# @todo
#   my $extract_status = $conf->{status} || 200;
#   if( $status != $extract_status ) {
#     $DEBUG and $ctx->_debug($req, "debug: - - status:$status not match with $extract_status");
#     next;
#   }
    # 抽出ルールは必須
    my $extract_list = $conf->{extract};
    if( !$extract_list ) {
      next;
    }
    # 配列でないなら配列にしてしまう
    if( ref($extract_list) ne 'ARRAY' ) {
      $extract_list = [$extract_list];
    }
	# 指定があるならそこに従う
	my $sepchr = $conf->{separator} || " ";
    # 抽出リスト処理
    foreach my $_extract (@$extract_list) {
      my $extract = $_extract; # sharrow-copy.
      $extract = ref($extract) ? $extract : qr/\Q$extract/;
      my @match;
      if( ref($extract) eq 'CODE' ) {
        # @todo
        #local($_) = $req->{result}{decoded_content};
        #@match = $extract->($req);
      } else {
        #@match = $req->{result}{decoded_content} =~ $extract;
        @match = $$text =~ $extract;
      }
      @match or next;
      @match == 1 && !defined($match[0]) and next;
#      $heading = $match[0];
	   $heading .= ' ' if ($heading ne "");
	   @match = grep { !/^$/ } @match;
	   $heading .= join($sepchr, @match);
      last;
    }
    defined($heading) or next;
    # 削除リスト処理
    my $remove_list = $conf->{remove};
    if( ref($remove_list) ne 'ARRAY' )
    {
      $remove_list = defined($remove_list) ? [$remove_list] : [];
    }
    foreach my $_remove (@$remove_list)
    {
      my $remove = $_remove; # sharrow-copy.
      $remove = ref($remove) ? $remove : qr/\Q$remove/;
      $heading =~ s/$remove//ig;
    }
    # 余計なタグの除去
    # @todo 長すぎる文字のトリム
    $heading =~ s/<.+?>//g;
	# タイトル指定
	my $ovwtitle = $conf->{title};
	$overwrite_title = "";
	$overwrite_title = $ovwtitle if ( defined($ovwtitle) );
  }
  # ここまでに情報が得られているなら
  if( defined($heading) && $heading =~ /\S/ ) {
    #$heading =~ s/\s+/ /g;
    $heading =~ s/^\s+//;
    $heading =~ s/\s+$//;

    my $title = $overwrite_title || HTMLTitle_Get( $text ); #$req->{result}{result};
	if ( $overwrite_title eq 'none' ) {
		$title = '';
	}
    $title = defined($title) && $title ne '' ? "$heading - $title" : $heading;
    #$req->{result}{result} = $title;
    return $title;
  }
  undef;
}

# <title> を拾う
sub HTMLTitle_Get {
    my ($text) = shift;
    my $string;
    $$text =~ s/<\!--.+?-->//g;
    if ( $$text =~ m|<title[^>]*>(.+?)</title>|ims ) {
		$string = $1;
		$string =~ s/[\r\n]//g;
		$string =~ s/\s+/ /g;
    }
    return $string;
}


# get from : http://cachu.xrea.jp/perl/GetPicSize.html
#############################################################################
#
# 画像のサイズ(幅と高さ)を取得するサブルーチン
#
#                    2001-2006 Copyright (C) cachu <cachu@cocoa.ocn.ne.jp>
#
#  使い方:
#
#      ( $format, $width, $height ) =  &GetImageSize( $FileName, [$out] );
#
#            $format : 画像フォーマット
#             $width : 幅
#            $height : 高さ
#          $FileName : 画像ファイル名
#               $out : ファイルハンドル(省略可)
#
#
#      ファイル名を引数として渡すと画像フォーマット、幅、高さの情報を
#   返します。画像フォーマットの値は
#
#       'JPEG-JFIF'       … JFIF フォーマットの JPEG 形式
#       'JPEG-JFIF-EXIF'  … JFIF フォーマットの JPEG 形式 (Exif 情報あり)
#       'JPEG-EXIF'       … Exif フォーマットの JPEG 形式
#       'PNG'             … PNG 形式
#       'GIF'             … GIF 形式
#       'BMP'             … Windows ビットマップ形式
#       'TIFF'            … TIFF 形式
#       'TIFF-EXIF'       … Exif フォーマットの TIFF 形式
#       'PBM'             … PBM 形式
#       'PGM'             … PGM 形式
#       'PPM'             … PPM 形式
#       'TGA'             … TGA 形式
#
#   となります。 Exif フォーマットの JPEG 画像(デジカメの画像)には
#   さまざまな情報が記録されています。その内容を表示したい場合には
#   ExifInfo.pl をご利用下さい。
#
#
#   2004/05/09 現在対応済画像フォーマット:
#       - GIF
#       - Windows Bit Map
#       - JPEG (JFIF)
#       - JPEG (Exif)
#       - TIFF
#       - TIFF (Exif)
#       - PNG
#       - PPM/PGM/PBM
#       - TGA
#
#   更新履歴
#      
#      ・2006/01/27 - バグ修正
#      ・2004/08/02 - バグ修正
#      ・2004/05/09 - Exif 情報の画像情報はオリジナルのものとは限らない
#                     ため JPEG 形式の処理の変更
#      ・2003/09/10 - 8/22 変更個所について処理する順番を変更した
#      ・2003/08/22 - 某サイトで取得できないというものに対応してみた
#                         + 試しですので採用するかどうかはまだ分かりません
#      ・2003/07/13 - Exif 形式の TIFF 画像の処理を追加
#      ・2003/05/27 - バグ修正
#      ・2003/03/27 - Exif 情報に関しては独立して別サブルーチン化した
#      ・2003/01/06 - 引数の調整
#      ・2002/12/15 - Exif 情報を返すようにした
#                         + まだ不完全(Olympus C-2 ZOOM で使われている
#                           タグしか処理していません)
#      ・2002/07/17 - PGM/PBM, TGA 形式に対応 (TGA 形式はちょっとあやしい…)
#      ・2002/07/04 - Exif 形式データ取得に関するバグ修正
#      ・2002/06/05 - Exif 形式データ取得に関するバグ修正
#                   - 読み込みをファイルハンドルからファイル名に修正
#      ・2001/12/14 - 初期バージョン
#
sub GetImageSize{
    my ( $IMG, $in ) = @_;
    my ( %SHT, %LNG );
    my ( $buf, $mark, $type, $f_size, $width, $height );
    my ( $TAG, $TYPE, $COUNT, $V_OFFSET, $PK, $ENTRY, $Exif_IFD );
    my ( $endian, $dummy1, $dummy2, $dummy, $EOI, $APP1, $length, $exif );
    my ( $format, $offset, $line, $CODE, $jfif, $i );
    my @TGA;
    my $ntag;

    # 定数
    $mark = pack("C", 0xff);
    %SHT = ( 'II' => 'v', 'MM' => 'n' );
    %LNG = ( 'II' => 'V', 'MM' => 'N' );

    # 初期値
    $endian   = '';
    $width    = -1;
    $height   = -1;
    $format   = '';
    $Exif_IFD = -1;

    if( $in eq '' ){
		$in = *IMG;
    }

    open( $in, $IMG ) || return( '', -1, -1 );

    binmode($in);
    seek( $in, 0, 0 );
    read( $in, $buf, 6 );

    # GIF 形式
    if($buf =~ /^GIF/i){
		$format = 'GIF';
		read( $in, $buf, 2 );
		$width  = unpack("v*", $buf);
		read( $in, $buf, 2);
		$height = unpack("v*", $buf);
    # Windows Bit Map 形式
    }elsif($buf =~ /BM/){
		$format = 'BMP';
		seek( $in, 12, 1 );
		read( $in, $buf, 8 );
		($width, $height) = unpack("VV", $buf);
    # TIFF 形式
    }elsif( $buf =~ /(II)/ || $buf =~ /(MM)/ ){
		$format = 'TIFF';
		$endian = $1;
		seek( $in, 0, 0 );
		read( $in, $buf, 8 );
		( $endian, $dummy1, $offset ) = 
		  unpack( "A2$SHT{$endian}$LNG{$endian}", $buf );

		seek( $in, $offset, 0 );
		read( $in, $buf, 2 );
		$ENTRY = unpack( $SHT{$endian}, $buf );

		for( $i = 0 ; $i < $ENTRY ; $i++ ){
			read( $in, $buf, 8 );
			$PK = "$SHT{$endian}$SHT{$endian}$LNG{$endian}";
			( $TAG, $TYPE, $COUNT ) = unpack( $PK, $buf );

			read( $in, $buf, 4 );
			( $TAG != 256 && $TAG != 257 ) and next;
			if( $TYPE == 3 ){
				$PK = "$SHT{$endian}";
			}elsif( $TYPE == 4 ){
				$PK = "$LNG{$endian}";
			}else{
				next;
			}
			$V_OFFSET = unpack( $PK, $buf );
			# Image width and height
			( $TAG == 256   ) and ( $width  = $V_OFFSET   );
			( $TAG == 257   ) and ( $height = $V_OFFSET   );
			( $TAG == 34665 ) and ( $format .= '-EXIF'    );
		}
		# PPM 形式
    }elsif( $buf =~ /^(P[123456])\n/ ){
		if( $1 eq 'P1' || $1 eq 'P4' ){
			$format = 'PBM';
		}elsif( $1 eq 'P2' || $1 eq 'P5' ){
			$format = 'PGM';
		}else{
			$format = 'PPM';
		}
		seek( $in, 0, 0 );
		<$in>;
		while( <$in> ){
			next if ( /^\#/ );
			chomp;
			( $width, $height ) = split( /\s+/, $_ );
			last;
		}
		# PNG 形式
    }elsif( $buf =~ /PNG/){
		$format = 'PNG';
		seek( $in, 8, 0 );
		while(1){
			read( $in, $buf, 8 );
			( $offset, $CODE ) = unpack( "NA4", $buf );
			if( $CODE eq 'IHDR' ){
				read( $in, $buf, 8 );
				( $width, $height ) = unpack( "NN", $buf );
				seek( $in, $offset-8+4, 1 );
				last;
			}elsif( $CODE eq 'IEND' ){
				last;
			}else{
				seek( $in, $offset+4, 1 );
			}
		}
    }else{
		# JPEG 形式
		seek( $in, 0, 0 );
		read( $in, $buf, 2 );
		( $buf, $type ) = unpack("C*", $buf );
		if( $buf == 0xFF && $type == 0xD8 ){
			$format = 'JPEG';
		  JPEG:while(read( $in, $buf, 1 )){
				if (($buf eq $mark) && read( $in, $buf, 3 )) {
					$type   = unpack("C*", substr($buf, 0, 1));
					$f_size = unpack("n*", substr($buf, 1, 2));

					( $type == 0xD9 ) and ( last JPEG );
					( $type == 0xDA ) and ( last JPEG );

					if ($type == 0xC0 || $type == 0xC2) {
						read( $in, $buf, $f_size-2 );
						$height = unpack("n*", substr($buf, 1, 2));
						$width  = unpack("n*", substr($buf, 3, 2));
						( $format =~ /EXIF/ ) and ( last JPEG );

					} elsif ( $type == 0xE1 ) {
						read( $in, $buf, $f_size-2 );
						$exif = unpack( "A4", substr( $buf, 0, 4 ) );
						if( $exif =~ /exif/i ){
							$format .= '-EXIF';
							( $width > 0 && $height > 0 ) and ( last JPEG );
						}
					} elsif ( $type == 0xE0 ) {
						read( $in, $buf, $f_size-2 );
						$jfif = unpack( "A4", substr( $buf, 0, 4 ) );
						if ( $jfif =~ /jfif/i ) {
							$format .= '-JFIF';
						}

					} elsif ( $type == 0x01 || $type == 0xFF ||
							  ( $type >= 0xD0 && $type < 0xD9 ) ) {
						seek( $in, -2, 1 );

					} else {
						read( $in, $buf, $f_size-2 );
					}
				}
			}
		}

		if ( $width > 0 && $height > 0 ) {
			close( $in );
			return( $format, $width, $height );
		}

		# TGA 形式
		seek( $in, 0, 0 );
		read( $in, $buf, 18 );
		@TGA = unpack( "CCCvvCvvvvCC", $buf );
		if ( $TGA[1] == 0 || $TGA[1] == 1 ) {
			if ( $TGA[2] ==  0 || $TGA[2] == 1 || $TGA[2] ==  2 ||
				 $TGA[2] ==  3 || $TGA[2] == 9 || $TGA[2] == 10 ||
				 $TGA[1] == 11 ) {
				$format = 'TGA';
				$width  = $TGA[8];
				$height = $TGA[9];
			}
		}

    }

    close( $in );
    return( $format, $width, $height );
}
#############################################################################

1;
