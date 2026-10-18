# Historical source and modern changes

The historical project implemented an HTTP service directly in PowerShell, combining `HttpListener`, reusable request script blocks, a `RunspacePool`, per-slot PowerShell instances, and asynchronous `BeginInvoke`/`EndInvoke` bookkeeping. The scheduler explicitly configured eight workers.

`historical/crm-scheduler.ps1.txt` preserves lines 662–736 of `crmAPI_runspaceEnabled.ps1`, with two explanatory header comments and normalized line endings. It is an inert `.txt` file, not a runnable dependency. Exact private backup locations and original-file hashes are retained outside this package. The public provenance file identifies only the original filename, line span, and excerpt hash.

Related `adAPI_runspaceEnabled.ps1` source reused this scheduler. An earlier `webDirector.ps1` used workflow/file slots for dispatch instead of runspaces; it is historical context, not code shipped here. No claim is made that this package is a byte-identical export of the old application.

## What the excerpt demonstrates

| Original lines | Mechanism / issue |
| --- | --- |
| 662–678 | Explicit eight-worker capacity and request-context slots |
| 679–700 | Searches for an available slot; saturation recursively retries without forwarding the pending context |
| 701–708 | Creates a PowerShell invocation, attaches the pool, passes request/context dependencies, then calls `BeginInvoke` |
| 710–720 | Reclamation iterates slot `i` but calls `EndInvoke` through `CurrentCon`, risking the wrong request's result |
| 723–736 | Synchronous HTTP acceptance and periodic cleanup, without a shutdown/disposal path |

The original worker invocation also passed one database-connection object across requests. The database, handlers, credentials, operational records, endpoint configuration, and certificate/signature block are deliberately outside the excerpt and package.

## Modernization in this package

All executable code, synthetic examples, and tests in this package are new maintenance work derived from that scheduling design. The original lifecycle defects are retained only in the inert excerpt so a reviewer can inspect the before/after mechanisms.

- One dispatcher owns admission, the FIFO queue, HTTP responses, and each job's invocation handle.
- Fixed active/queue bounds replace recursive retry and preserve every accepted context.
- Fresh request runspaces replace the original reusable pool. This improves session-state isolation at the cost of setup overhead.
- Handlers receive request data and a cancellation token, and return response data. HTTP contexts and shared database connections do not cross into workers.
- End-to-end deadlines, explicit cancellation, cooperative shutdown, generic HTTP errors, and guaranteed disposal after invocation completion are covered by loopback tests.

These changes demonstrate how the original concurrency mechanism can be maintained responsibly. They do not establish production performance, process isolation, or hard cancellation of arbitrary native code.
