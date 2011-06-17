#!/bin/perl
use strict;
use DBI;

die "Usage: $0 path/to/cookies.sqlite\n" unless @ARGV;
my $dbfile = shift;
die "$0: $dbfile: No such file or directory\n" unless -e $dbfile;

binmode STDOUT;
print "# HTTP Cookie File\n";
print "# http://wp.netscape.com/newsref/std/cookie_spec.html\n";
print "# This is a generated file!  Do not edit.\n";
print "# To delete cookies, use the Cookie Manager.\n";
print "\n";

my $dbh = DBI->connect("dbi:SQLite:dbname=$dbfile", "", "", {RaiseError => 1});
my $sth = $dbh->prepare("SELECT host, path, isSecure, expiry, name, value, isHttpOnly FROM moz_cookies ORDER BY id DESC");
$sth->execute();
while (my ($host, $path, $isSecure, $expiry, $name, $value, $isHttpOnly) = $sth->fetchrow_array) {
    print join("\t", $isHttpOnly ? "#HttpOnly_$host" : $host, $host =~ /^\./ ? 'TRUE' : 'FALSE', $path, $isSecure ? 'TRUE' : 'FALSE', $expiry, $name, $value), "\n";
}
undef $sth;
$dbh->disconnect();
