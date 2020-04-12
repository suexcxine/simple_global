simple_global
=====

* A simple gen_server callback module for global name register.
* Eventual consistency for simplicity and performance.
* One process is allowed to have multiple names.
* Processes are only allowed to register/unregister from their own nodes, for consistency.

Build
-----

    $ ./rebar3 compile

