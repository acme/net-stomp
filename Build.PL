#!perl
use Module::Build;
use strict;
use warnings;

my $build = Module::Build->new(
    create_makefile_pl => 'traditional',
    license            => 'perl',
    module_name        => 'Net::Stomp',
    requires           => {
        'IO::Socket::INET'      => '0',
        'IO::Select'            => '0',
        'Class::Accessor::Fast' => '0',
    },
);
$build->create_build_script;
