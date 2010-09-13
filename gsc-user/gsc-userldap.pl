#! /gsc/bin/perl
# Manage LDAP users
# Copyright (C) 2008 Washington University in St. Louis
#
# This program is free software; you can redistribute it and/or modify
# it under the same terms as Perl itself.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

use warnings;
use strict;
use Getopt::Long;
use IO::Handle;
use Net::LDAP;
use Pod::Usage;
use Term::ReadKey;

my $pkg = 'gsc-userldap';
my $version = '0.4';

if (!&GetOptions(help => sub { &pod2usage(-exitval => 0) },
                 version => sub { print "$pkg $version\n"; exit 0 }))
{
    warn("Try ``$pkg --help'' for more information.\n");
    exit(1);
}

# parse command line
my $action = shift(@ARGV);
my $uid = shift(@ARGV);

# prompt for password
STDOUT->autoflush(1);
ReadMode('noecho');
STDOUT->print("$pkg: enter ldap admin password: ");
my $secret = ReadLine(0);
ReadMode('normal');
chomp($secret);
STDOUT->print("\n");

# connect to ldap server
my $dn = 'cn=admin,dc=gsc,dc=wustl,dc=edu';
my $server = 'ldapmaster.gsc.wustl.edu';
my $ldap = Net::LDAP->new($server, version => 3);
if (!$ldap) {
    warn("$pkg: failed to create handle to ldap server");
    exit(2);
}
# start_tls so we can bind secure
my $msg = $ldap->start_tls(verify => 'none');
if ($msg->is_error()) {
    warn("$pkg: error when starting TLS: ", $msg->error());
    exit(2);
}

# bind to server
$msg = $ldap->bind($dn, password => $secret);
if ($msg->is_error()) {
    warn("$pkg: error when binding: ", $msg->error());
    exit(2);
}

# see what should be done
if ($action eq 'add') {
    # get rest of parameters from command line
    my ($uidNumber, $fullname, $shell, $gid, $group_list) = @ARGV;

    # split fullname into first and last
    my ($firstname, $lastname) = split(/\s+/, $fullname, 2);

    # add entry to People directory
    my $lastChange = int time / 86400 - 360;
	
	$msg = $ldap->add("uid=$uid,ou=People,dc=gsc,dc=wustl,dc=edu",
                      attrs => [
                                uid => $uid,
                                objectClass => [
				    qw(inetLocalMailRecipient person
                                       organizationalPerson inetOrgPerson
                                       posixAccount top shadowAccount sambaSamAccount) 
                                ],
                                cn => $fullname,
                                gecos => $fullname,
                                gidNumber => $gid,
                                givenName => $firstname,
                                sn => $lastname,
                                homeDirectory => "/gscuser/$uid",
                                loginShell => $shell,
                                mail => "$uid\@genome.wustl.edu",
                                mailHost => 'genome.wustl.edu',
                                mailRoutingAddress => "$uid\@genome.wustl.edu",
                                shadowLastChange => $lastChange,
                                shadowMax => 365,
                                uidNumber => $uidNumber,
                                userPassword => 'genomes1',
								sambaSID => 'S-1-0-0'
                                ]
                      );
    if ($msg->is_error()) {
        warn("$pkg: error when adding user $uid: ", $msg->error());
        exit(2);
    }

    # add user into correct groups
    if ($group_list) {
        foreach my $group (split(m/,/, $group_list)) {
            $msg = $ldap->modify("cn=$group,ou=Group,dc=gsc,dc=wustl,dc=edu",
                                 add => { memberUid => $uid });
            if ($msg->is_error()) {
                warn("$pkg: error when modifying Group $group: ", $msg->error());
                exit(2);
            }
        }
    }
}
elsif ($action eq 'delete') {
    # find groups user is in
    my $search_result = $ldap->search(base => 'ou=Group,dc=gsc,dc=wustl,dc=edu',
                                      filter => "(memberUid=$uid)",
                                      attrs => ['cn']);
    if ($search_result->is_error) {
        warn("$pkg: search for groups failed: $uid: ", $search_result->error);
        exit(2);
    }
    my @groups = map { $_->get_value('cn') } $search_result->entries;

    # delete user from groups
    foreach my $group (@groups) {
        $msg = $ldap->modify("cn=$group,ou=Group,dc=gsc,dc=wustl,dc=edu",
                             delete => { memberUid => $uid });
        if( $msg->is_error() ) {
            warn("$pkg: error when deleting user $uid from group $group: ",
                 $msg->error());
            exit(2);
        }
    }

    # delete the people entry
    my $msg = $ldap->delete("uid=$uid,ou=People,dc=gsc,dc=wustl,dc=edu");
    if ($msg->is_error()) {
        warn("Error when deleting user $uid: ", $msg->error());
        exit(2);
    }
}
elsif ($action eq 'lock') {
    # change shell and remove password (so password authentication fails)
    my $msg = $ldap->modify("uid=$uid,ou=People,dc=gsc,dc=wustl,dc=edu",
                            replace => { loginShell => '/bin/false' },
                            delete => [ 'userPassword' ]
                           );
    if ($msg->is_error()) {
        warn("Error locking user $uid: ", $msg->error());
        exit(2);
	}
	# add user to NoSsh group
    my $msg2 = $ldap->modify("cn=NoSsh,ou=Group,dc=gsc,dc=wustl,dc=edu",
                            add => { memberUid => $uid });
    if ($msg2->is_error()) {
        warn("$pkg: error when modifying Group NoSsh: ", $msg2->error());
        exit(2);
    }
    my $msg3 = $ldap->modify("uid=$uid,ou=People,dc=gsc,dc=wustl,dc=edu",
                            delete => [ 'sambaNTPassword' ]
                           );
    if ($msg3->is_error()) {
        warn("Samba NT credential not present, so no need to remove it");
    }
    my $msg4 = $ldap->modify("uid=$uid,ou=People,dc=gsc,dc=wustl,dc=edu",
                            delete => [ 'sambaLMPassword' ]
                           );
    if ($msg4->is_error()) {
        warn("Samba LM credential not present, so no need to remove it");
    }
}
elsif ($action eq 'unlock') {
    # get shell
    my ($shell, $pw) = @ARGV;

    # change shell and remove password (so password authentication fails)
    my $msg = $ldap->modify("uid=$uid,ou=People,dc=gsc,dc=wustl,dc=edu",
                            replace => { loginShell => $shell },
                            add => { userPassword => $pw }
                           );
    if ($msg->is_error()) {
        warn("Error unlocking user $uid: ", $msg->error());
        exit(2);
    }
    # remove user from NoSsh group
    my $msg2 = $ldap->modify("cn=NoSsh,ou=Group,dc=gsc,dc=wustl,dc=edu",
                            delete => { memberUid => $uid });
    if ($msg2->is_error()) {
        warn("$pkg: error when modifying Group NoSsh: ", $msg2->error());
        exit(2);
    }
}
else {
    warn("$pkg: invalid action: $action");
    exit(1);
}

# disconnect
$ldap->unbind;

exit 0;

__END__
# max uid
$searchresult = $ldap->search(base => "ou=People,dc=gsc,dc=wustl,dc=edu",
                              filter => "(uidNumber=*)",
                              attrs => ['uidNumber']);
$searchresult->code && die $mesg->error;
my $highuid = 0;
@myentries = $searchresult->entries;
foreach $entry ( @myentries ) {
    $uid = $entry->get_value("uidNumber");
    if( $uid > $highuid && $uid < 60000 ) {
        $highuid = $uid;
    }
}

# ldapmodify
ldapmodify -x -Z -W -D 'cn=admin,dc=gsc,dc=wustl,dc=edu' <<EOF
dn: uid=$login,ou=People,dc=gsc,dc=wustl,dc=edu
changetype: modify
replace: loginShell
loginShell: /bin/false
-
delete: userPassword
EOF

=pod

=head1 NAME

gsc-userldap - manage user information in LDAP directory

=head1 SYNOPSIS

B<gsc-userldap> add LOGIN UID 'FULL NAME' SHELL GID GROUP_LIST

B<gsc-userldap> delete LOGIN

B<gsc-userldap> lock LOGIN

B<gsc-userldap> unlock LOGIN SHELL PASSWORD

=head1 DESCRIPTION

This script modifies the LDAP directory by adding, deleting, locking,
and unlocking user accounts.  When unlocking, you will be prompted for
the user password.

=head1 OPTIONS

No options.

=head1 BUGS

Please report bugs to the hardware queue of RT, http://rt.gsc.wustl.edu/.

=head1 SEE ALSO

Net::LDAP(3)

=head1 AUTHOR

David Dooling <ddooling@wustl.edu>

=cut