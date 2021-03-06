Goiardi
=======

[![Circle CI](https://circleci.com/gh/ctdk/goiardi/tree/master.svg?style=svg&circle-token=849db1a2f08048be1253cfb876483949b4dc7d7e)](https://circleci.com/gh/ctdk/goiardi/tree/master)

Goiardi is an implementation of the Chef server (http://www.opscode.com) written
in Go. It can either run entirely in memory with the option to save and load the
in-memory data and search indexes to and from disk, drawing inspiration from
chef-zero, or it can use MySQL or PostgreSQL as its storage backend.

DOCUMENTATION
-------------
The full goiardi documentation has been moved out of this README because it was
getting too big to be easily manageable. It now uses sphinx to manage and format
the documentation, which can be found under the `docs/` directory. To learn
about sphinx-doc, see http://sphinx-doc.org/. The documentation can also be
found online at http://goiardi.readthedocs.org/en/latest/.

In addition to the aforementioned Chef documentation at http://docs.opscode.com,
more documentation specific to goiardi can be viewed with godoc. See
http://godoc.org/code.google.com/p/go.tools/cmd/godoc for an explanation of how
godoc works. The goiardi godocs can also be viewed online at
http://godoc.org/github.com/ctdk/goiardi.

TODO
----

See the TODO file for an up-to-date list of what needs to be done. There's a
lot.

BUGS
----

There's going to be a lot of these for a while, so we'll just keep those in a
BUGS file, won't we?

WHY?
----

This started as a project to learn Go, and because I thought that an in memory
chef server would be handy. Then I found out about chef-zero, but I still wanted
a project to learn Go, so I kept it up. Chef 11 Server also only runs under
Linux at this time, while Goiardi is developed under Mac OS X and ought to run
under any platform Go supports (only partially tested at this time though).

CONTRIBUTING
------------

If you feel like contributing, great! Just fork the repo, make your
improvements, and submit a pull request. Tests would, of course, be appreciated.
Adding tests where there are no tests currently would be even more appreciated.
At least, though, try and not break anything worse than it is. Test coverage has
improved, but is still an ongoing concern.

AUTHOR
------

Jeremy Bingham (<jeremy@goiardi.gl>)

COPYRIGHT
---------

Copyright 2013-2014, Jeremy Bingham

LICENSE
-------

Like many Chef ecosystem programs, goairdi is licensed under the Apache 2.0
License. See the LICENSE file for details.

The goiardi documentation in the `docs` directory is licensed under a Creative
Commons Attribution 4.0 International (CC-BY 4.0) License.

Chef is copyright (c) 2008-2014 Chef Software (formerly Opscode, Inc.) and its
various contributors.

Thanks go out to the fine folks of Opscode and the Chef community for all their
hard work.

Also, if you were wondering, Ettore Boiardi was the man behind Chef Boyardee.
Wakka wakka.
