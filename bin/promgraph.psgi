#!perl
# PODNAME: promgraph.psgi

use 5.020;
use warnings;
use strict;

use lib qw(lib);

use Promgraph;

Promgraph->to_app;
