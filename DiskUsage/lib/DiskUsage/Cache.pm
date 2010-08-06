
package DiskUsage::Cache;

use strict;
use warnings;
use Data::Dumper;

use English;

use Cwd 'abs_path';
use DBI;
use Time::HiRes qw(usleep);
use File::Basename;
use File::Find::Rule;

use Exception::Class::TryCatch;
use DiskUsage::Error;

# -- Subroutines
#
sub new {
  my $class = shift;
  my $self = {
    parent => shift,
  };
  bless $self, $class;
  return $self;
}

sub error {
  # Raise an Exception object.
  my $self = shift;
  $self->logger("Error: @_");
  DiskUsage::Error->throw( error => @_ );
}

sub logger {
  my $self = shift;
  my $fh = $self->{parent}->{logfh};
  print $fh localtime() . ": @_";
}

sub local_debug {
  my $self = shift;
  $self->logger("DEBUG: @_")
    if ($self->{parent}->{debug});
}

sub sql_exec {
  # Execute SQL.  Retry N times then give up.

  my $self = shift;
  my $sql = shift;

  my @args = ();
  @args = @_
    if $#_ > -1;

  my $dbh = $self->{dbh};
  my $sth;
  my $attempts = 0;

  $self->error("no database handle, run prep()\n")
    if (! defined $dbh);
  $self->error("no SQL provided\n")
    if (! defined $sql);

  while (1) {

    my $result;
    my $max_attempts = 3;

    $self->local_debug("sql_exec($sql) with args " . Dumper(@args) . "\n");

    try eval {
      $sth = $dbh->prepare($sql);
    };
    if (catch my $err) {
      $self->error("could not prepare sql: " . $err->{message});
    }

    my $rows;
    try eval {
      $sth->execute(@args);
      $rows = $sth->fetchall_arrayref();
    };
    # Note: we expect only one row
    if ( catch my $err ) {
      $attempts += 1;
      if ($attempts >= $max_attempts) {
        $self->error("failed during execute $attempts times, giving up: $err->{message}\n");
      } else {
        $self->logger("failed during execute $attempts times, retrying: $err->{message}\n");
      }
      usleep(10000);
    } else {
      $self->local_debug("success: " . $sth->rows . ": " . Dumper($rows) . "\n");
      return $rows;
    }
  }
}

sub prep {
  # Connect to the cache.
  my $self = shift;
  my $cachefile = $self->{parent}->{cachefile};

  $self->local_debug("prep()\n");

  $self->error("cachefile is undefined\n")
    if (! defined $cachefile);
  if (-f $cachefile) {
    $self->logger("using existing cache $cachefile\n");
  } else {
    open(DB,">$cachefile") or
      $self->error("failed to create new cache $cachefile: $!\n");
    close(DB);
    $self->logger("creating new cache $cachefile\n");
  }

  my $connected = 0;
  my $retries = 0;
  my $max_retries = $self->{parent}->{config}->{db_tries};
  my $dsn = "DBI:SQLite:dbname=$cachefile";

  while (!$connected and $retries < $max_retries) {

    $self->logger("SQLite trying to connect: $retries: $cachefile\n");

    try eval {
      $self->{dbh} = DBI->connect( $dsn,"","",
          {
            PrintError => 0,
            AutoCommit => 1,
            RaiseError => 1,
          }
        ) or $self->error("couldn't connect to database: " . $self->{dbh}->errstr);
      $connected = 1;
    };

    if ( catch my $err ) {
      $retries += 1;
      $self->logger("SQLite can't connect, retrying: $cachefile: $!\n");
      sleep(1);
    };

  }

  $self->error("SQLite can't connect after $max_retries tries, giving up\n")
    if (!$connected);

  $self->local_debug("Connected to: $cachefile\n");

  # FIXME: These tables could include DISK_DF, DISK_DF_DG, DISK_GROUP
  # but DISK_GROUP exists in OLTP already.

  # disk_df table and triggers
  my $sql = "CREATE TABLE IF NOT EXISTS disk_df (df_id INTEGER PRIMARY KEY AUTOINCREMENT, mount_path VARCHAR(255), physical_path VARCHAR(255), total_kb UNSIGNED INTEGER NOT NULL DEFAULT 0, used_kb UNSIGNED INTEGER NOT NULL DEFAULT 0, group_name VARCHAR(255), created DATE, last_modified DATE)";
  $self->sql_exec($sql);

  $sql = "CREATE TRIGGER IF NOT EXISTS disk_df_update_created AFTER INSERT ON disk_df BEGIN UPDATE disk_df SET created = DATETIME('NOW') where rowid = new.rowid; END;";
  $self->sql_exec($sql);

  $sql = "CREATE TRIGGER IF NOT EXISTS disk_df_update_last_modified AFTER UPDATE ON disk_df BEGIN UPDATE disk_df SET last_modified = DATETIME('NOW') where rowid = new.rowid; END;";
  $self->sql_exec($sql);

  # disk_hosts table and triggers
  $sql = "CREATE TABLE IF NOT EXISTS disk_hosts (host_id INTEGER PRIMARY KEY AUTOINCREMENT, hostname VARCHAR(255), snmp_ok UNSIGNED INTEGER NOT NULL DEFAULT 0, created DATE NOT NULL DEFAULT '0000-00-00 00:00:00', last_modified DATE NOT NULL DEFAULT '0000-00-00 00:00:00')";
  $self->sql_exec($sql);

  # set created after insert
  $sql = "CREATE TRIGGER IF NOT EXISTS disk_hosts_update_created AFTER INSERT ON disk_hosts  BEGIN UPDATE disk_hosts SET created = DATETIME('NOW') where rowid = new.rowid; END;";
  $self->sql_exec($sql);

  # set last modified after insert if snmp_ok is 1
  $sql = "CREATE TRIGGER IF NOT EXISTS disk_hosts_insert_last_modified AFTER INSERT ON disk_hosts WHEN new.snmp_ok = 1 BEGIN UPDATE disk_hosts SET last_modified = DATETIME('NOW') where rowid = new.rowid; END;";
  $self->sql_exec($sql);

  # set last modified after update if snmp_ok is 1
  $sql = "CREATE TRIGGER IF NOT EXISTS disk_hosts_update_last_modified AFTER UPDATE OF snmp_ok ON disk_hosts WHEN new.snmp_ok = 1 BEGIN UPDATE disk_hosts SET last_modified = DATETIME('NOW') where rowid = new.rowid; END;";
  $self->sql_exec($sql);

}

sub disk_hosts_add {
  my $self = shift;
  my $host = shift;
  my $result = shift;
  my $err = shift;
  my $snmp_ok;
  if ($err) {
    $snmp_ok = -1;
  } else {
    $snmp_ok = scalar keys %$result ? 1 : 0;
  }

  $self->local_debug("disk_hosts_add($host,$result)\n");

  my $sql = "SELECT host_id FROM disk_hosts where hostname = ?";
  my $res = $self->sql_exec($sql,($host) );

  my @args = ();
  if ( $#$res == -1 ) {
    $sql = "INSERT INTO disk_hosts (hostname,snmp_ok) VALUES (?,?)";
    @args = ($host,$snmp_ok);
  } else {
    # trivial update triggers the trigger.
    $sql = "UPDATE disk_hosts SET hostname=?, snmp_ok=?  WHERE hostname=?";
    @args = ($host,$snmp_ok,$host);
  }
  return $self->sql_exec($sql,@args);
}

sub disk_df_add {
  # Update cache, note insert or update.
  # params is a hash of df items:
  #   my $params = {
  #     'physical_path' => "/vol/sata800",
  #     'mount_path' => "/gscmnt/sata800",
  #     'total_kb' => 1000,
  #     'used_kb' => 900,
  #     'group_name' => 'PRODUCTION',
  #   };
  my $self = shift;
  my $params = shift;

  $self->local_debug("disk_df_add()" . Dumper($params) . "\n");

  foreach my $key ( 'mount_path', 'physical_path', 'total_kb', 'used_kb', 'group_name' ) {
    $self->error("params is missing key: $key\n")
      if (! exists $params->{$key});
  }

  # Determine if row is present, and thus whether this is an
  # insert or update.
  my $sql = "SELECT df_id FROM disk_df where physical_path = ?";
  my $res = $self->sql_exec($sql,( $params->{'physical_path'} ) );

  my @args = ();
  if ( $#$res == -1 ) {
    $sql = "INSERT INTO disk_df
            (mount_path,physical_path,group_name,total_kb,used_kb)
            VALUES (?,?,?,?,?)";
    if (ref($params) eq 'HASH') {
      foreach my $key ( 'mount_path', 'physical_path', 'group_name', 'total_kb', 'used_kb' ) {
        push @args, $params->{$key}
          if (defined $params->{$key});
      }
    }
  } else {
    $sql = "UPDATE disk_df
            SET mount_path=?,group_name=?,total_kb=?,used_kb=?
            WHERE physical_path = ?";
    if (ref($params) eq 'HASH') {
      foreach my $key ( 'mount_path', 'group_name', 'total_kb', 'used_kb', 'physical_path' ) {
        push @args, $params->{$key}
          if (defined $params->{$key});
      }
    }
  }

  return $self->sql_exec($sql,@args);
}

sub fetch {
  # Fetch an item from the cache.
  my $self = shift;
  my $key = shift;
  my $value = shift;

  my $sql = "SELECT * FROM disk_df WHERE $key = ?";
  $self->local_debug("fetch($sql)");
  return $self->sql_exec($sql,$value);
}

1;

__END__