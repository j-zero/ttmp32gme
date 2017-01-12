#!/usr/bin/env perl

package main;

use strict;
use warnings;

use EV;
use AnyEvent::Impl::EV;
use AnyEvent::HTTPD;
use AnyEvent::HTTP;

use PAR;

use Encode qw(decode_utf8 encode_utf8);

use Path::Class;

use Text::Template;
use JSON::XS;
use URI::Escape;
use Getopt::Long;
use Perl::Version;
use DBI;
use DBIx::MultiStatementDo;
use Log::Message::Simple qw(msg error);

use lib ".";

use TTMp32Gme::LibraryHandler;
use TTMp32Gme::TttoolHandler;
use TTMp32Gme::PrintHandler;

# Set the UserAgent for external async requests.  Don't want to get flagged, do we?
$AnyEvent::HTTP::USERAGENT =
'Mozilla/5.0 (Windows; U; Windows NT 6.1; en-US; rv:1.9.2.10) Gecko/20100914 Firefox/3.6.10 ( .NET CLR 3.5.30729)';

# Declare globals... I know tisk tisk
my ( $dbh, %config, $watchers, %templates, $static, %assets );

# Encapsulate configuration code
{
	my $port;
	my $directory  = "";
	my $configdir  = "";
	my $configfile = "";
	my $versionFlag;

	my $version = Perl::Version->new("0.1.0");

# Command line startup options
# Usage: ttmp32gme(.exe) [-d|--directory=dir] [-p|--port=port#] [-c|--configdir=dir] [-v|--version]
	GetOptions(
		"port=i" => \$port,    # Port for the local web server to run on
		"directory=s" =>
			\$directory,    # Directory to change to after starting (for dev mostly)
		"configdir=s" => \$configdir,    # Where your config files are located
		"version"     => \$versionFlag
	);                                 # Get the version number

	if ($versionFlag) {
		print STDOUT "mp32gme version $version\n";
		exit(0);
	}

	if ($directory) {
		chdir($directory);
	}

	use TTMp32Gme::Build::FileHandler;

	my $configFile = checkConfigFile();
	unless ($configFile) {
		die "Could not find config file.\n";
	}

	$dbh = DBI->connect( "dbi:SQLite:dbname=$configFile", "", "" )
		or die "Could not open config file.\n";
	%config = fetchConfig();

	my $dbVersion = Perl::Version->new( $config{'version'} );
	if ( $version->numify > $dbVersion->numify ) {
		print STDOUT "Updating config...\n";

		require TTMp32Gme::DbUpdate;
		TTMp32Gme::DbUpdate::update( $dbVersion, $dbh );

		print STDOUT "Update successful.\n";
		%config = fetchConfig();
	}

	# Port setting from the command line is temporary
	if ($port) {
		$config{'port'} = $port;
	}
}

%templates = loadTemplates();
$static    = loadStatic();
%assets    = loadAssets();

sub fetchConfig {
	my $configArrayRef =
		$dbh->selectall_arrayref(q( SELECT param, value FROM config ))
		or die "Can't fetch configuration\n";

	my %tempConfig = ();
	foreach my $cfgParam (@$configArrayRef) {
		$tempConfig{ $$cfgParam[0] } = $$cfgParam[1];
	}

	return %tempConfig;
}

sub save_config {
	my ($configParams) = @_;
	my $qh = $dbh->prepare('UPDATE config SET value=? WHERE param=?');
	foreach my $param (%$configParams) {
		$qh->execute( $configParams->{$param}, $param );
		if ( $qh->errstr ) { last; }
	}
	return fetchConfig();
}

sub getNavigation {
	my ( $url, $siteMap, $siteMapOrder ) = @_;
	my $nav = "";
	foreach my $path (
		sort { $siteMapOrder->{$a} <=> $siteMapOrder->{$b} }
		keys %$siteMap
		)
	{
		if ( $url eq $path ) {
			$nav .= "<li class='active'><a href='$path'>$siteMap->{$path}</a></li>";
		} else {
			$nav .= "<li><a href='$path'>$siteMap->{$path}</a></li>";
		}
	}
	return $nav;
}

my %siteMap = (
	'/' =>
'<span class="glyphicon glyphicon-upload" aria-hidden="true"></span> Upload',
	'/library' =>
'<span class="glyphicon glyphicon-th-list" aria-hidden="true"></span> Library',

#	'/print' => '<span class="glyphicon glyphicon-print" aria-hidden="true"></span> Print',
	'/config' =>
'<span class="glyphicon glyphicon-cog" aria-hidden="true"></span> Configuration',
	'/help' =>
'<span class="glyphicon glyphicon-question-sign" aria-hidden="true"></span> Help',
);

my %siteMapOrder = (
	'/'        => 0,
	'/library' => 10,

	#	'/print' => 2,
	'/config' => 98,
	'/help'   => 99,
);

my $httpd =
	AnyEvent::HTTPD->new( host => $config{'host'}, port => $config{'port'} );
msg(
	"Server running on port: $config{'port'}\n"
		. "Open http://127.0.0.1:$config{'port'}/ in your favorite web browser to continue.\n",
	1
);

if (-X get_executable_path('tttool')) {
	msg( "using tttool: " . get_executable_path('tttool'), 1 );
} else{
	error( "no useable tttool found: " . get_executable_path('tttool'), 1 );
}

if ( $config{'open_browser'} eq 'TRUE' ) { openBrowser(%config); }

my $fileCount  = 0;
my $albumCount = 0;

#normally the temp directory 0 stays empty, but we need to create it
#in case the browser was still open with files dropped when we started
my $currentAlbum = makeTempAlbumDir($albumCount);
my @fileList;
my @albumList;

$httpd->reg_cb(
	'/' => sub {
		my ( $httpd, $req ) = @_;
		if ( $req->method() eq 'GET' ) {
			$albumCount++;
			$fileCount    = 0;
			$currentAlbum = makeTempAlbumDir($albumCount);
			$req->respond(
				{
					content => [
						'text/html',
						$templates{'base'}->fill_in(
							HASH => {
								'title'         => $siteMap{ $req->url },
								'strippedTitle' => $siteMap{ $req->url } =~ s/<span.*span> //r,
								'navigation' =>
									getNavigation( $req->url, \%siteMap, \%siteMapOrder ),
								'content' => $static->{'upload.html'}
							}
						)
					]
				}
			);
		} elsif ( $req->method() eq 'POST' ) {

			#print Dumper($req);
			my $content       = { 'success' => \0 };
			my $statusCode    = 501;
			my $statusMessage = 'Could not parse POST data.';
			if ( $req->parm('qquuid') ) {
				if ( $req->parm('_method') ) {

					#delete temporary uploaded files
					my $fileToDelete = $albumList[$albumCount]{ $req->parm('qquuid') };
					my $deleted      = unlink $fileToDelete;
					print $fileToDelete. "\n";
					if ($deleted) {
						$content->{'success'} = \1;
						$statusCode           = 200;
						$statusMessage        = 'OK';
					}
				} elsif ( $req->parm('qqfile') ) {
					$fileList[$fileCount] = $req->parm('qquuid');
					my $currentFile;
					if ( $req->parm('qqfilename') ) {
						$currentFile = file( $currentAlbum, $req->parm('qqfilename') );
					} else {
						$currentFile = file( $currentAlbum, $fileCount );
					}
					$albumList[$albumCount]{ $fileList[$fileCount] } = $currentFile;
					$currentFile->spew( iomode => '>:raw', $req->parm('qqfile') );
					$fileCount++;
					$content->{'success'} = \1;
					$statusCode           = 200;
					$statusMessage        = 'OK';
				}
			} elsif ( $req->parm('action') ) {
				print "copying albums to library\n";
				createLibraryEntry( \@albumList, $dbh, $httpd );
				$fileCount            = 0;
				$albumCount           = 0;
				$currentAlbum         = makeTempAlbumDir($albumCount);
				@fileList             = ();
				@albumList            = ();
				$content->{'success'} = \1;
				$statusCode           = 200;
				$statusMessage        = 'OK';
			}
			$content = encode_json($content);
			$req->respond(
				[
					$statusCode, $statusMessage,
					{ 'Content-Type' => 'application/json' }, $content
				]
			);
		}
	},
	'/library' => sub {
		my ( $httpd, $req ) = @_;
		if ( $req->method() eq 'GET' ) {
			$req->respond(
				{
					content => [
						'text/html',
						$templates{'base'}->fill_in(
							HASH => {
								'title'         => $siteMap{ $req->url },
								'strippedTitle' => $siteMap{ $req->url } =~ s/<span.*span> //r,
								'navigation' =>
									getNavigation( $req->url, \%siteMap, \%siteMapOrder ),
								'content' => $static->{'library.html'}
							}
						)
					]
				}
			);
		} elsif ( $req->method() eq 'POST' ) {

			#print Dumper($req);
			my $content       = { 'success' => \0 };
			my $statusCode    = 501;
			my $statusMessage = 'Could not parse POST data.';
			if ( $req->parm('action') ) {
				if ( $req->parm('action') eq 'list' ) {
					$statusMessage =
						'Could not get list of albums. Possible database error.';
					$content->{'list'} = get_album_list( $dbh, $httpd );
					if (get_tiptoi_dir) {
						$content->{'tiptoi_connected'} = \1;
					}
				} elsif (
					$req->parm('action') =~ /(update|delete|cleanup|make_gme|copy_gme)/ )
				{
					my $postData =
						decode_json( uri_unescape( encode_utf8( $req->parm('data') ) ) );
					if ( $req->parm('action') eq 'update' ) {
						$statusMessage = 'Could not update database.';
						$content->{'element'} =
							get_album_online( updateAlbum( $postData, $dbh ), $httpd, $dbh );
					} elsif ( $req->parm('action') eq 'delete' ) {
						$statusMessage = 'Could not update database.';
						$content->{'element'}{'oid'} =
							deleteAlbum( $postData->{'uid'}, $httpd, $dbh );
					} elsif ( $req->parm('action') eq 'cleanup' ) {
						$statusMessage = 'Could not clean up album folder.';
						$content->{'element'} =
							get_album_online(
							cleanupAlbum( $postData->{'uid'}, $httpd, $dbh ),
							$httpd, $dbh );
					} elsif ( $req->parm('action') eq 'make_gme' ) {
						$statusMessage = 'Could not create gme file.';
						$content->{'element'} =
							get_album_online( make_gme( $postData->{'uid'}, \%config, $dbh ),
							$httpd, $dbh );
					} elsif ( $req->parm('action') eq 'copy_gme' ) {
						$statusMessage = 'Could not copy gme file.';
						$content->{'element'} =
							get_album_online( copy_gme( $postData->{'uid'}, \%config, $dbh ),
							$httpd, $dbh );
					}
				} elsif ( $req->parm('action') eq 'add_cover' ) {
					$statusMessage = 'Could not update cover. Possible i/o error.';
					$content->{'uid'} = get_album_online(
						replace_cover(
							$req->parm('uid'),    $req->parm('qqfilename'),
							$req->parm('qqfile'), $httpd,
							$dbh
						),
						$httpd, $dbh
					);
				}
			}
			if ( !$dbh->errstr ) {
				$content->{'success'} = \1;
				$statusCode           = 200;
				$statusMessage        = 'OK';
			} else {
				$statusCode    = 501;
				$statusMessage = $dbh->errstr;
			}
			$content = decode_utf8( encode_json($content) );
			$req->respond(
				[
					$statusCode, $statusMessage,
					{ 'Content-Type' => 'application/json' }, $content
				]
			);
		}
	},
	'/print' => sub {
		my ( $httpd, $req ) = @_;
		if ( $req->method() eq 'GET' ) {
			my $getData =
				decode_json( uri_unescape( encode_utf8( $req->parm('data') ) ) );
			$req->respond(
				{
					content => [
						'text/html',
						$templates{'print'}->fill_in(
							HASH => {
								'title' =>
'<span class="hidden-print"><span class="glyphicon glyphicon-print" aria-hidden="true"></span> Print</span>',
								'strippedTitle' => 'Print',
								'navigation' =>
									getNavigation( $req->url, \%siteMap, \%siteMapOrder ),
								'content' => create_print_layout(
									$getData->{'oids'}, $templates{'printing_contents'},
									\%config, $httpd, $dbh
								)
							}
						)
					]
				}
			);
		} elsif ( $req->method() eq 'POST' ) {

			#print Dumper($req);
			my $content       = { 'success' => \0 };
			my $statusCode    = 501;
			my $statusMessage = 'Could not parse POST data.';
			if ( $req->parm('action') eq 'get_config' ) {
				$statusMessage =
					'Could not get configuration. Possible database error.';
				$content->{'element'} = \%config;
			} elsif ( $req->parm('action') eq 'save_config' ) {
				my $postData =
					decode_json( uri_unescape( encode_utf8( $req->parm('data') ) ) );
				$statusMessage        = 'Could not save configuration.';
				%config               = save_config($postData);
				$content->{'element'} = \%config;
			}
			if ( !$dbh->errstr ) {
				$content->{'success'} = \1;
				$statusCode           = 200;
				$statusMessage        = 'OK';
			} else {
				$statusCode    = 501;
				$statusMessage = $dbh->errstr;
			}
			$content = decode_utf8( encode_json($content) );
			$req->respond(
				[
					$statusCode, $statusMessage,
					{ 'Content-Type' => 'application/json' }, $content
				]
			);
		}
	},
	'/config' => sub {
		my ( $httpd, $req ) = @_;
		if ( $req->method() eq 'GET' ) {

			my $configHtml = $templates{'config'}->fill_in(
				HASH => {
					'host'         => $config{'host'},
					'port'         => $config{'port'},
					'open_browser' => $config{'open_browser'} eq 'TRUE'
					? 'checked="checked"'
					: '',
					'audio_format' => $config{'audio_format'}
				}
			);
			$req->respond(
				{
					content => [
						'text/html',
						$templates{'base'}->fill_in(
							HASH => {
								'title'         => $siteMap{ $req->url },
								'strippedTitle' => $siteMap{ $req->url } =~ s/<span.*span> //r,
								'navigation' =>
									getNavigation( $req->url, \%siteMap, \%siteMapOrder ),
								'content' => $configHtml
							}
						)
					]
				}
			);
		} elsif ( $req->method() eq 'POST' ) {
			if ( $req->parm('action') eq 'update' ) {
				my $configParams =
					decode_json( uri_unescape( encode_utf8( $req->parm('data') ) ) );
				%config = save_config($configParams);
				my $status;
				if ( !$dbh->errstr ) {
					$status = 'Success.';
				} else {
					$status = 'Could not update config.  Try reloading ttmp32gme.';
				}

				$req->respond(
					{
						content =>
							[ 'application/json', '{ "status" : "' . $status . '" }' ]
					}
				);
			}
		}
	},
	'/help' => sub {
		my ( $httpd, $req ) = @_;
		$req->respond(
			{
				content => [
					'text/html',
					$templates{'base'}->fill_in(
						HASH => {
							'title'         => $siteMap{ $req->url },
							'strippedTitle' => $siteMap{ $req->url } =~ s/<span.*span> //r,
							'navigation' =>
								getNavigation( $req->url, \%siteMap, \%siteMapOrder ),
							'content' => $static->{'help.html'}
						}
					)
				]
			}
		);
	},
	%assets
);

$httpd->run;    # making a AnyEvent condition variable would also work

