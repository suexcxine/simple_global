simple_global
=====

* A simple gen_server callback module for global name register.
* Eventual consistency for simplicity and performance.
* One process is allowed to have multiple names.
* Processes are only allowed to register/unregister from their own nodes, for consistency.

Build
-----

    $ ./rebar3 compile

Show Case
-----

### start three nodes and simple_global, connect a and b

```
$ erl -sname a -setcookie abc -pa _build/default/lib/simple_global/ebin/
a> net_kernel:connect_node('b@MacBook-Pro').
true
a> simple_global:start().
{ok,<0.120.0>}

$ erl -sname b -setcookie abc -pa _build/default/lib/simple_global/ebin/
b> simple_global:start().
{ok,<0.98.0>}

$ erl -sname c -setcookie abc -pa _build/default/lib/simple_global/ebin/
c> simple_global:start().
{ok,<0.105.0>}
```

### register a name and see it's synced within a and b nodes

```
a> simple_global:register_name(test, self()).
yes
a> ets:tab2list(simple_global).
[{test,<0.116.0>,local,#Ref<0.176713640.3089891331.128970>,
       #{}},
 {{ref,#Ref<0.176713640.3089891331.128970>},test}]

b> ets:tab2list(simple_global).
[{test,<9356.116.0>,'a@MacBook-Pro',undefined,#{}}]

a> simple_global:set_meta(test, #{a => 123}).
ok
a> ets:tab2list(simple_global).
[{test,<0.116.0>,local,#Ref<0.176713640.3089891331.128970>,
       #{a => 123}},
 {{ref,#Ref<0.176713640.3089891331.128970>},test}]

b> ets:tab2list(simple_global).
[{test,<9356.116.0>,'a@MacBook-Pro',undefined,
       #{a => 123}}]
```

### let node c join the cluster and see it gets data

```
c> ets:tab2list(simple_global).
[]
c> net_kernel:connect_node('a@MacBook-Pro').
true
c> ets:tab2list(simple_global).
[{test,<9324.116.0>,'a@MacBook-Pro',undefined,
       #{a => 123}}]
```

### update meta data, only allowed in the node where the process was registered

```
c> simple_global:set_meta(test, #{a => 456}).
error

a> simple_global:set_meta(test, #{a => 456}).
ok
a> ets:tab2list(simple_global).
[{test,<0.116.0>,local,#Ref<0.176713640.3089891331.128970>,
       #{a => 456}},
 {{ref,#Ref<0.176713640.3089891331.128970>},test}]

b> ets:tab2list(simple_global).
[{test,<9356.116.0>,'a@MacBook-Pro',undefined,
       #{a => 456}}]

c> ets:tab2list(simple_global).
[{test,<9324.116.0>,'a@MacBook-Pro',undefined,
       #{a => 456}}]
```

### when disconnects, registry will be removed since the process is no longer accessible

```
c> net_kernel:disconnect('a@MacBook-Pro').
true
c> net_kernel:disconnect('b@MacBook-Pro').
true
> ets:tab2list(simple_global).
[]
```

### when name clash happens, for example, when joining a cluster, processes registered in a smaller(compared with <) nodename win, the other process will be killed

```
c> simple_global:register_name(test, self()).
yes
c> ets:tab2list(simple_global).
[{test,<0.128.0>,local,#Ref<0.1190508258.1479016450.19536>,
       #{}},
 {{ref,#Ref<0.1190508258.1479016450.19536>},test}]
c> net_kernel:connect_node('a@MacBook-Pro').
true
=ERROR REPORT==== 28-Apr-2021::18:41:24.756659 ===
simple_global: Name conflict, terminating {test,<0.128.0>}

** exception exit: killed

c> ets:tab2list(simple_global).
[{test,<9324.116.0>,'a@MacBook-Pro',undefined,
       #{a => 456}}]

a> ets:tab2list(simple_global).
[{test,<0.116.0>,local,#Ref<0.176713640.3089891331.128970>,
       #{a => 456}},
 {{ref,#Ref<0.176713640.3089891331.128970>},test}]

```
