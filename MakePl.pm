#!/usr/bin/perl
=cut

MakePl - Portable drop-in build system
https://github.com/quietfanatic/make-pl
2013-09-27

USAGE: See the README in the above repo.

=====LICENSE=====

The MIT License (MIT)

Copyright (c) 2013 Lewis Wall

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

=================

=cut

package MakePl;

use strict;
use warnings; no warnings 'once';
use feature qw(switch say);
use autodie;
no autodie 'chdir';
use Exporter;
use Carp qw(croak);
use Cwd qw(realpath);
use subs qw(cwd chdir);
use File::Spec::Functions qw(:ALL);

our @ISA = 'Exporter';
our @EXPORT = qw(make rule phony subdep defaults include config option cwd chdir targetmatch run slurp splat);
our %EXPORT_TAGS = ('all' => \@EXPORT);


##### GLOBALS
 # Caches the current working directory
our $cwd = Cwd::cwd();
 # This variable is initialized on import.
our %project;
 # This is set to 0 when recursing.
our $this_is_root = 1;
 # Set once only.
our $original_base = cwd;
 # Prevent double-inclusion; can't use %INC because it does relative paths.
our %included = (realpath($0) => 1);
 # A cache of file modification times.  It's probably safe to keep until exit.
my %modtimes;
 # Just keep track.
my %configs;
 # Defined later
my %builtin_options;
my %custom_options;
 # Taken as needed from the command line.
our %options;
my $force = 0;
my $verbose = 0;
my $simulate = 0;

##### STARTING

sub import {
    unless (%project) {
        my ($package, $file, $line) = caller;
        %project = (
            caller_package => $package,
            caller_file => $file,
            caller_line => $line,
            rules => [],
            targets => {},
            subdeps => {},
            auto_subdeps => [],
            autoed_subdeps => {},
            phonies => {},
            defaults => undef,
            made => 0,
        );
         # Get directory of the calling file, which may not be cwd
        my @vdf = splitpath(rel2abs($file));
        my $base = catpath($vdf[0], $vdf[1], '');
        my $old_cwd = cwd;
        chdir $base;
    }
    MakePl->export_to_level(1, @_);
     # Also import strict and warnings.
    strict->import();
    warnings->import();
}


END {
    if ($? == 0 and !$project{made}) {
        warn "\e[31m✗\e[0m $project{caller_file} did not end with 'make;'\n";
    }
}

##### DECLARING RULES

 # caller abstracted out because phony() delegates to this as well.
sub rule_with_caller {
    my ($to, $from, $recipe, $package, $file, $line) = @_;
    ref $recipe eq 'CODE' or croak "Non-code recipe given to rule";
    my $rule = {
        caller_file => $file,
        caller_line => $line,
        base => cwd,
        to => [arrayify($to)],
        from => lazify($from),
        deps => undef,  # Generated from from
        recipe => $recipe,
        check_stale => undef,
        config => 0,
        planned => 0,  # Intrusive state for the planning phase
    };
    push @{$project{rules}}, $rule;
    for (@{$rule->{to}}) {
        push @{$project{targets}{realpath($_)}}, $rule;
    }
}
sub rule ($$$) {
    %project or croak "rule was called before importing MakePl";
    rule_with_caller(@_, caller);
}
sub phony ($;$$) {
    %project or croak "phony was called before importing MakePl";
    @_ == 2 and croak "phony was given 2 arguments, but it must have either 1 or 3";
    for (arrayify($_[0])) {
        $project{phonies}{realpath($_)} = 1;
    }
    rule_with_caller(@_, caller) if @_ > 1;
}
sub subdep ($;$) {
    %project or croak "subdep was called before importing MakePl";
    my ($to, $from) = @_;
    if (ref $to eq 'CODE') {
        push @{$project{auto_subdeps}}, {
            base => cwd,
            code => $to
        };
    }
    elsif (defined $from) {
        my $subdep = {
            base => cwd,
            to => [arrayify($to)],
            from => lazify($from),
        };
        for (@{$subdep->{to}}) {
            push @{$project{subdeps}{realpath($_)}}, $subdep;
        }
    }
    else {
        croak 'subdep must be called with two arguments unless the first is a CODE ref';
    }
}
sub arrayify {
    return ref $_[0] eq 'ARRAY' ? @{$_[0]} : $_[0];
}
sub lazify {
    my ($dep) = @_;
    return ref $dep eq 'CODE' ? $dep : [arrayify($dep)];
}
sub delazify {
     # Works on subdeps too
    my ($rule) = @_;
    if (ref $rule->{from} eq 'CODE') {
        $rule->{from} = [$rule->{from}(@{$rule->{to}})];
    }
}

##### OTHER DECLARATIONS

sub defaults {
    push @{$project{defaults}}, map realpath($_), @_;
}
sub include {
    for (@_) {
        my $file = $_;
         # Error on specific files, but skip directories.
        -e $file or croak "Cannot include $file because it doesn't exist";
        if (-d $file) {
            my $makepl = catfile($file, 'make.pl');
            next unless -e $makepl;
            $file = $makepl;
        }
         # Skip already-included files
        my $real = realpath($file);
        next if $included{$real};
        $included{real} = 1;
         # Make new project.
        my $this_project = \%project;
        local $this_is_root = 0;
        local %project;
        do {
            package main;
            my $old_cwd = MakePl::cwd;
            do $file;  # This file will do its own chdir
            MakePl::chdir $old_cwd;
            $@ and die_status $@;
        };
        if (!$project{made}) {
            die "\e[31m✗\e[0m $project{caller_file} did not end with 'make;'\n";
        }
        %project or return;  # Oops, it wasn't a make.pl, but we did it anyway
         # merge projects
        push @{$this_project->{rules}}, @{$project{rules}};
        for (keys %{$project{targets}}) {
            push @{$this_project->{targets}{$_}}, @{$project{targets}{$_}};
        }
        $this_project->{phonies} = {%{$this_project->{phonies}}, %{$project{phonies}}};
        for (keys %{$project{subdeps}}) {
            push @{$this_project->{subdeps}{$_}}, @{$project{subdeps}{$_}};
        }
        push @{$this_project->{auto_subdeps}}, @{$project{auto_subdeps}};
    }
}

##### CONFIGURATION

sub corrupted { return "\e[31m✗\e[0m Corrupted config file $_[0]$_[1]; please delete it and try again.\n"; }
sub read_config {
    my ($file, $str) = @_;
    my ($val, $rest) = read_thing($file, $str);
    $rest eq '' or die corrupted($file, " (extra junk at end)");
    return $val;
}
sub read_thing {
    my ($file, $s) = @_;
    my $string_rx = qr/"((?:\\\\|\\"|[^\\"])*)"/s;
    if ($s =~ s/^\{//) {  # Hash
        my %r;
        unless ($s =~ s/^}//) {
            while (1) {
                $s =~ s/^$string_rx://
                    or die corrupted($file, " (didn't find key after {)");
                my $key = $1;
                $key =~ s/\\([\\"])/$1/g;
                (my $val, $s) = read_thing($file, $s);
                $r{$key} = $val;
                next if $s =~ s/^,//;
                last if $s =~ s/^}//;
                die corrupted($file, " (unrecognized char in hash)");
            }
        }
        return (\%r, $s);
    }
    elsif ($s =~ s/^\[//) {  # Array
        my @r;
        unless ($s =~ s/^]//) {
            while (1) {
                (my $val, $s) = read_thing($file, $s);
                push @r, $val;
                next if $s =~ s/^,//;
                last if $s =~ s/^]//;
                die corrupted($file, " (unrecognized char in array)");
            }
        }
        return (\@r, $s);
    }
    elsif ($s =~ /^"/) {  # String
        $s =~ s/^$string_rx//
            or die corrupted($file, " (malformed string or something)");
        my $r = $1;
        $r =~ s/\\([\\"])/$1/g;
        return ($r, $s);
    }
    elsif ($s =~ s/^null//) {
        return (undef, $s);
    }
    else {
        die corrupted($file, " (unknown character in term position)");
    }
}
sub show_thing {
    my ($thing) = @_;
    if (not defined $thing) {
        return 'null';
    }
    elsif (ref $thing eq 'HASH') {
        my $r = '{';
        $r .= join ',', map {
            my $k = $_;
            $k =~ s/([\\"])/\\$1/g;
            "\"$k\":" . show_thing($thing->{$_});
        } sort keys %$thing;
        return $r . '}';
    }
    elsif (ref $thing eq 'ARRAY') {
        return '[' . (join ',', map show_thing($_), @$thing) . ']';
    }
    elsif (ref $thing eq '') {
        $thing =~ s/([\\"])/\\$1/g;
        return "\"$thing\"";
    }
    else {
        croak "Cannot serialize object of ref type '" . ref $thing . "'";
    }
}

sub config {
    %project or croak "config was called before importing MakePl";
    my ($filename, $var, $routine) = @_;
    grep ref $var eq $_, qw(SCALAR ARRAY HASH)
        or croak "config's second argument is not a SCALAR, ARRAY, or HASH ref (It's a " . ref($var) . " ref)";
    !defined $routine or ref $routine eq 'CODE'
        or croak "config's third argument is not a CODE ref";
    my ($package, $file, $line) = caller;
    my $rule = {
        base => cwd,
        to => [$filename],
        from => [],
        deps => [],
        check_stale => sub { stale_config($filename, $var); },
        recipe => sub { gen_config($filename, $var, $routine); },
        caller_file => $file,
        caller_line => $line,
        config => 1,
        planned => 0,
        stale => 0,
    };
    push @{$project{rules}}, $rule;
    push @{$project{targets}{realpath($filename)}}, $rule;
    $configs{realpath($filename)} = 1;
     # Read into $var immediately
    if (-e $filename) {
        my $str = slurp($filename);
        chomp $str;
        my $val = read_config($filename, $str);
        if (ref $var eq 'SCALAR') {
            $$var = $val;
        }
        elsif (ref $var eq 'ARRAY') {
            ref $val eq 'ARRAY' or die corrupted($filename, " (expected ARRAY, got " . ref($val) . ")");
            @$var = @$val;
        }
        elsif (ref $var eq 'HASH') {
            ref $val eq 'HASH' or die corrupted($filename, " (expected HASH, got " . ref($val) . ")");
            %$var = %$val;
        }
    }
}

sub stale_config ($$) {
    my ($filename, $var) = @_;
    return 1 unless -e $filename;
    my $old = slurp($filename);
    chomp $old;
    my $new = show_thing(ref $var eq 'SCALAR' ? $$var : $var);
    return $new ne $old;
}

sub gen_config ($$$) {
    my ($filename, $var, $routine) = @_;
    $routine->() if defined $routine;
    my $new = show_thing(ref $var eq 'SCALAR' ? $$var : $var);
    splat($filename, "$new\n");
}

%builtin_options = (
    help => {
        ref => sub {
            say "\e[31m✗\e[0m Usage: $0 <options> <targets>";
            if (%custom_options) {
                say "Custom options:";
                for (sort keys %custom_options) {
                    say "    ", $custom_options{$_}{desc} // "--$_";
                }
            }
            if (%builtin_options) {
                say "General options:";
                for (sort keys %builtin_options) {
                    say "    $builtin_options{$_}{desc}";
                }
            }
            say "Final targets:";
            for (sort grep target_is_final($_), keys %{$project{targets}}) {
                say "    ", abs2rel($_), target_is_default($_) ? " (default)" : "";
            }
            exit 1;
        },
        desc => "--help - show this help message",
        custom => 0
    },
    'list-targets' => {
        ref => sub {
            say "\e[31m✗\e[0m All targets:";
            for (sort keys %{$project{targets}}) {
                say "    ", abs2rel($_), target_is_default($_) ? " (default)" : "";
            }
            exit 1;
        },
        desc => "--list-targets - list all declared targets",
        custom => 0
    },
    force => {
        ref => \$force,
        desc => '--force - Skip modification time checks',
        custom => 0
    },
    verbose => {
        ref => \$verbose,
        desc => '--verbose - Show sub-dependencies and shell commands',
        custom => 0
    },
    simulate => {
        ref => \$simulate,
        desc => '--simulate - Show rules that would be run but don\'t run them',
        custom => 0
    },
);

sub option ($$;$) {
    %project or croak "option was called before importing MakePl";
    my ($name, $ref, $desc) = @_;
    if (ref $name eq 'ARRAY') {
        &option($_, $ref, $desc) for @$name;
        return;
    }
    elsif (ref $ref eq 'SCALAR' or ref $ref eq 'CODE') {
        $custom_options{$name} = {
            ref => $ref,
            desc => $desc,
            custom => 1
        };
        delete $builtin_options{$name};
    }
    else {
        croak "Second argument to option is not a SCALAR or CODE ref";
    }
     # Immediately find option.
    unless (%options) {
        for (@ARGV) {
            if ($_ eq '--') {
                last;
            }
            elsif (/^--no-([^=]+)$/) {
                $options{$1} = 0;
            }
            elsif (/^--([^=]+)(?:=(.*))?$/) {
                $options{$1} = $2 // 1;
            }
        }
    }
    if (exists $options{$name}) {
        if (ref $ref eq 'SCALAR') {
            $$ref = $options{$name};
        }
        elsif (ref $ref eq 'CODE') {
            $ref->($options{$name});
        }
    }
}

##### DIRECTORY HANDLING
 # Cwd::cwd is super slow, so we should do it as little as possible.
sub cwd () {
    return $cwd;
}
sub chdir ($) {
    $cwd eq $_[0] or Cwd::chdir($cwd = $_[0]);
}

##### UTILITIES

sub targetmatch {
    my ($rx) = @_;
    return grep $_ =~ $rx, map abs2rel($_), keys %{$project{targets}};
}

sub show_command (@) {
    my (@command) = @_;
    for (@command) {
        if (/\s/) {
            $_ =~ s/'/'\\''/g;
            $_ = "'$_'";
        }
    }
    return join ' ', @command;
}

sub run (@) {
    if ($verbose) {
        say show_command(@_);
    }
    system(@_) == 0 or do {
        my @command = @_;
         # As per perldoc -f system
        if ($? == -1) {
            status("☢ Couldn't start command: $!");
        }
        elsif ($? & 127) {
            status(sprintf "☢ Command died with signal %d, %s coredump",
               ($? & 127),  ($? & 128) ? 'with' : 'without');
        }
        else {
            status(sprintf "☢ Command exited with value %d", $? >> 8);
        }
        die_status("☢ Failed command: " . show_command(@_));
    }
}

sub realpaths (@) {
    return map {
        my $r = realpath($_);
        unless (defined $r) {
            my $abs = rel2abs($_);
            croak "\"$abs\" doesn't seem to be a real path";
        }
        $r;
    } @_;
}

sub target_is_final ($) {
    my $old_cwd = cwd;
    for (@{$project{rules}}) {
        chdir $_->{base};
        delazify($_);
        for (@{$_->{from}}) {
            if (realpath($_) eq $_[0]) {
                chdir $old_cwd;
                return 0;
            }
        }
    }
    chdir $old_cwd;
    return 1;
}

sub target_is_default ($) {
    if (defined $project{defaults}) {
        my $is = grep $_ eq $_[0], @{$project{defaults}};
        return $is;
    }
    else {
        my $rule = $project{rules}[0];
        defined $rule or return 0;
        my $old_cwd = cwd;
        chdir $rule->{base};
        for (@{$rule->{to}}) {
            if (realpath($_) eq $_[0]) {
                chdir $old_cwd;
                return 1;
            }
        }
        chdir $old_cwd;
        return 0;
    }
}

sub slurp {
    my ($file, $bytes) = @_;
    open my $F, '<', $file;
    my $r;
    if (defined $bytes) {
        read $F, $r, $bytes;
    }
    else {
        local $/; $r = <$F>;
    }
    close $F;
    return $r;
}
sub splat {
    my ($file, $string) = @_;
    open my $F, '>', $file;
    print $F $string;
    close $F;
}

##### PRINTING ETC.

sub directory_prefix {
    my ($d, $base) = @_;
    $d //= cwd;
    $base //= $original_base;
    $d =~ s/\/*$//;
    $base =~ s/\/*$//;
    return $d eq $base
        ? ''
        : '[' . abs2rel($d, $base) . '/] ';
}
sub status {
    if ($verbose) {
        say "\e[36m", directory_prefix(), @_, "\e[0m";
    }
    else {
        say directory_prefix(), @_;
    }
}
sub die_status {
    status @_;
    die "\n";
}
sub show_rule ($) {
    if ($verbose) {
        resolve_deps($_[0]);
        return "@{$_[0]{to}} ← " . join ' ', map abs2rel($_), $_[0]{deps};
    }
    else {
        my @froms = grep !$configs{realpath($_)}, @{$_[0]{from}};
        @froms or @froms = @{$_[0]{from}};
        return "@{$_[0]{to}} ← " . join ' ', @froms;
    }
}
sub debug_rule ($) {
    return "$_[0]{caller_file}:$_[0]{caller_line}: " . directory_prefix($_[0]{base}) . show_rule($_[0]);
}

##### FILE INSPECTION UTILITIES
 # These work with absolute paths.

sub fexists {
    return 0 if $project{phonies}{$_[0]};
    return -e $_[0];
}
sub modtime {
    return $modtimes{$_[0]} //= (fexists($_[0]) ? (stat $_[0])[9] : 0);
}

##### PLANNING

sub init_plan {
    return {  # We had and might have more real stuff here
        stack => [],
        program => []
    };
}

sub plan_target {
    my ($plan, $target) = @_;
     # Make sure the file exists or there's a rule for it
    my $rel = abs2rel($target, $original_base);
    unless ($project{targets}{$target} or fexists($target)) {
        my $mess = "☢ Cannot find or make $rel" . (@{$plan->{stack}} ? ", required by\n" : "\n");
        for my $rule (reverse @{$plan->{stack}}) {
            $mess .= "\t" . debug_rule($rule) . "\n";
        }
        die_status $mess;
    }
     # In general, there should be only rule per target, but there can be more.
    return grep plan_rule($plan, $_), @{$project{targets}{$target}};
}

sub get_auto_subdeps {
    return map {
        my $target = $_;
        @{$project{autoed_subdeps}{$target} //= [
            map {
                chdir $_->{base};
                realpaths($_->{code}($target));
            } @{$project{auto_subdeps}}
        ]}
    } @_;
}
sub push_new {
    my ($deps, @new) = @_;
    push @$deps, grep {
        my $d = $_;
        not grep $d eq $_, @$deps;
    } @new;
}

sub resolve_deps {
    my ($rule) = @_;
     # Get the realpaths of all dependencies and their subdeps
    chdir $rule->{base};
    delazify($rule);
    my @deps = realpaths(@{$rule->{from}});
     # Using this style of loop because @deps will keep expanding.
    for (my $i = 0; $i < @deps; $i++) {
        push_new(\@deps, get_auto_subdeps($deps[$i]));
        for my $subdep (@{$project{subdeps}{$deps[$i]}}) {
            chdir $subdep->{base};
            delazify($subdep);
            push_new(\@deps, realpaths(@{$subdep->{from}}));
        }
    }
    chdir $rule->{base};
    $rule->{deps} = [@deps];
}

sub plan_rule {
    my ($plan, $rule) = @_;
    chdir $rule->{base};
     # detect loops
    if (not defined $rule->{planned}) {
        my $mess = "☢ Dependency loop\n";
        for my $old (reverse @{$plan->{stack}}) {
            $mess .= "\t" . debug_rule($old) . "\n";
            die_status $mess if $rule eq $old;  # reference compare
        }
        Carp::confess $mess . "\t...oh wait, false alarm.  Which means there's a bug in make.pm.\nDetected";
    }
    elsif ($rule->{planned}) {
        return $rule->{stale};  # Already planned
    }
    push @{$plan->{stack}}, $rule;
    $rule->{planned} = undef;  # Mark that we're currently planning this

     # Now is when we officially collapse lazy dependencies and stuff like that
    resolve_deps($rule);
     # always recurse to plan_target
    my $stale = grep plan_target($plan, $_), @{$rule->{deps}};
    $stale ||= $force;
    $stale ||= $rule->{check_stale}() if defined $rule->{check_stale};
    $stale ||= grep {
        my $abs = realpath(rel2abs($_, $rule->{base}));
        !fexists($abs) or grep modtime($abs) < modtime($_), @{$rule->{deps}};
    } @{$rule->{to}};
    push @{$plan->{program}}, $rule if $stale;
     # Done planning this rule
    $rule->{planned} = 1;
    $rule->{stale} = $stale;
    pop @{$plan->{stack}};
    return $stale;
}

##### RUNNING

sub make () {
    if ($project{made}) {
        say "\e[31m✗\e[0m make was called twice in the same project.";
        exit 1;
    }
    $project{made} = 1;
    if ($this_is_root) {
        my @args = make_cmdline(@ARGV);
        my @program = make_plan(@args);
        make_execute(@program);
        exit 0;
    }
    1;
}

sub make_cmdline (@) {
    my $double_minus = 0;
    my @args;
    eval {
        for (@_) {
            if ($double_minus) {
                push @args, $_;
            }
            elsif ($_ eq '--') {
                $double_minus = 1;
            }
            elsif (/^--(no-)?([^=]*)(?:=(.*))?$/) {
                my ($no, $name, $val) = ($1, $2, $3);
                if (exists $custom_options{$name}) {
                     # We already processed this
                }
                elsif (my $opt = $builtin_options{$name}) {
                    if (ref $opt->{ref} eq 'SCALAR') {
                        ${$opt->{ref}} = $val // ($no ? 0 : 1);
                    }
                    else {
                        $opt->{ref}($val // ($no ? 0 : 1));
                    }
                }
                else {
                    say "\e[31m✗\e[0m Unrecognized option --$name.  Try --help to see available options.";
                    exit 1;
                }
            }
            else {
                push @args, $_;
            }
        }
    };
    if ($@) {
        warn $@ unless "$@" eq "\n";
        say "\e[31m✗\e[0m Nothing was done due to command-line error.";
        exit 1;
    }
    return @args;
}


sub make_plan (@) {
    my (@args) = @_;
    my $plan = init_plan();
    eval {
        if (@args) {
            grep plan_target($plan, realpath($_)), @args;
        }
        elsif ($project{defaults}) {
            grep plan_target($plan, $_), @{$project{defaults}};
        }
        else {
            plan_rule($plan, $project{rules}[0]);
        }
    };
    if ($@) {
        warn $@ unless "$@" eq "\n";
        say "\e[31m✗\e[0m Nothing was done due to error.";
        exit 1;
    }
    return @{$plan->{program}};
}

sub make_execute (@) {
    my @program = @_;
    if (not @{$project{rules}}) {
        say "\e[32m✓\e[0m Nothing was done because no rules have been declared.";
    }
    elsif (not @program) {
        say "\e[32m✓\e[0m All up to date.";
    }
    else {
        my $old_cwd = cwd;
        for my $rule (@program) {
            chdir rel2abs($rule->{base});
            status $rule->{config} ? "⚒ " : "⚙ ", show_rule($rule);
            delazify($rule);
            unless ($simulate) {
                eval { $rule->{recipe}->($rule->{to}, $rule->{from}) };
                if ($@) {
                    warn $@ unless "$@" eq "\n";
                    say "\e[31m✗\e[0m Did not finish due to error.";
                    chdir $old_cwd;
                    exit 1;
                }
            }
        }
        if ($simulate) {
            say "\e[32m✓\e[0m Simulation finished.";
        }
        else {
            say "\e[32m✓\e[0m Done.";
        }
        chdir $old_cwd;
    }
}


##### Generate a make.pl scaffold

if ($^S == 0) {  # We've been called directly
    if (@ARGV != 1 or $ARGV[0] eq '--help') {
        say "\e[31m✗\e[0m Usage: perl $0 <directory (default: .)>";
        exit 1;
    }
    my $loc = $ARGV[0];
    defined $loc or $loc = cwd;
    my $dir;
    if (-d $loc) {
        $loc = "$loc/make.pl";
        $dir = $loc;
    }
    elsif (-e $loc) {
        say "\e[31m✗\e[0m Did not generate $loc because it already exists.";
        exit 1;
    }
    elsif ($loc =~ /^(.*)\/[^\/]*$/) {
        $dir = $1;
    }
    else {
        $dir = cwd;
    }
    my $path_to_pm = abs2rel(rel2abs(__FILE__), $dir);
    $path_to_pm =~ s/[\\']/\\$1/g;
    open my $MAKEPL, '>', "$loc";
    print $MAKEPL <<"END";
#!/usr/bin/perl
use File::Spec::Functions ':ALL';
use lib catpath((splitpath rel2abs __FILE__)[0,1], '$path_to_pm');
use MakePl;

 # Sample rules
rule \$program, \$main, sub {
    run "gcc -Wall \\Q\$main\\E -o \\Q\$program\\E";
};
rule 'clean', [], sub { unlink \$program; };

make;
END
    chmod 0755, $MAKEPL;
    close $MAKEPL;
    say "\e[32m✓\e[0m Generated $loc.";
}

1;
