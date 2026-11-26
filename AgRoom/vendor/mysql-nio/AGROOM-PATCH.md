# MySQLNIO provenance

Vendored from Vapor MySQLNIO tag `1.9.1`, commit `7fa8530`:
https://github.com/vapor/mysql-nio/tree/1.9.1

The upstream MIT license is retained in `LICENSE`. Only the package manifest,
library sources, license and README are included. Remove the unused upstream test
target from the vendored manifest; AgRoom tests exercise the connector boundary.
The TLS dependency refers to the sibling vendored `swift-nio-ssl` package so SPM
and Xcode use exactly the same package identity and source.

`MySQLConnectionHandler.handleHandshake` rejects a server without `CLIENT_SSL`
when the caller supplies TLS configuration, before writing credentials. Upstream
uses opportunistic TLS. AgRoom requires certificate and hostname verification for
remote MySQL connections, and only permits explicit plaintext for loopback hosts.
No trust-all configuration or automatic TLS downgrade is exposed.
Missing server TLS support throws the typed `secureConnectionRequired` error so
the host can present a TLS-specific failure without parsing server diagnostics.

The only use of Swift Algorithms (a cycling XOR in RSA password encoding) is
replaced with the equivalent bounded standard-library indexing operation, with
an explicit empty-seed check. This removes that otherwise unused dependency.

The query command's deinit assertion is removed: cancelling a connection may
abandon an in-flight prepared statement, which the server releases with that
connection. Cancellation must not trap in Debug builds. Driver logging is disabled
by the host connector and raw driver errors are never returned to the UI.

The connection exposes an optional host channel-registration hook before protocol
setup and a bounded TCP connect timeout. Transport loss completes handshake/auth
promises exactly once, including close-before-authentication and setup failure.
The host cancels the registered channel and waits for driver futures to settle
before shutting down its event loop; it never destroys an event loop beneath
pending authentication or query futures.

Protocol handlers are installed in the channel initializer before TCP activation,
so an immediately sent server greeting cannot race an empty client pipeline.
