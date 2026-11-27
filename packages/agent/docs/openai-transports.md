# OpenAI transport reference

## Configuration and routing

- [Provider settings](../src/provider_settings.zig):
  `initWithCodexTransportDefault`, `environmentTransport`, and `initOptions`
  define environment inputs, defaults, credentials, and endpoint validation.
- [Minimal startup](../../cpi_minimal/src/main.zig): search for
  `configured_transport` for the environment override.
  [`Settings.codexTransportPreference`](../../cpi_minimal/src/config/Settings.zig)
  maps the saved preference;
  [`ModelSelection`](../../cpi_minimal/src/providers/ModelSelection.zig)
  supplies route defaults.
- [Provider dispatch](../src/provider.zig): `Service.requestRoute` handles
  admission, refresh and retries; `transportCall` checks the endpoint and
  credential and dispatches the exchange.
  [Minimal's `ScopedRoutes`](../../cpi_minimal/src/providers/ScopedRoutes.zig)
  supplies the saved-route refresh implementation.

## Wire format and decoding

- [Request projection and event decoding](../src/responses.zig): `wireValue`
  defines the fields sent for each dialect; `Decoder.event`, `streamTerminal`,
  and `interpret` turn provider events into a run result. For an output-limit
  investigation, inspect the projected request rather than the application's
  token setting.
- [HTTP `call`](../src/responses_http.zig): see `is_sse` for parser selection
  and `Decoder` for stream framing. For a Codex HTTP reply without
  `Content-Type`, trace `is_sse` and the body framing separately. Compare
  OpenAI's
  [Responses streaming guide](https://developers.openai.com/api/docs/guides/streaming-responses)
  for the public API with the
  [Codex HTTP client](https://github.com/openai/codex/blob/main/codex-rs/codex-api/src/endpoint/responses.rs),
  `stream_encoded`, and its
  [SSE parser](https://github.com/openai/codex/blob/main/codex-rs/codex-api/src/sse/responses.rs),
  `process_sse`.
- [WebSocket exchange](../src/responses_websocket.zig): `Link.upgrade` and
  `Link.request` cover the handshake and exchange; `failed` and
  `connectionInterrupted` cover fallback; `exchange` handles stale continuation
  recovery. [Session socket policy](../src/CodexSessions.zig) lives in
  `Session.acquire`, `Session.preferSse`, and `Lease.release`.
  [`State.delta`](../src/CodexContinuation.zig) decides when to send a
  continuation instead of full input. Socket reuse and context reuse are
  separate decisions.

## Native resume

For recovery, distinguish reattaching to an existing response, polling it, and
starting a fresh generation. A fresh generation can incur new charges. Local
cancellation and remote cancellation are separate operations.

- [`Provider.supportsNativeResume`](../src/provider_settings.zig) defines route
  eligibility.
  [OpenAI's background mode guide](https://developers.openai.com/api/docs/guides/background)
  describes the upstream API.
- [`responses_http.Decoder.dispatch`](../src/responses_http.zig) validates
  streamed response IDs and cursors.
  [`resumeStream`, `poll`, and `cancelBackground`](../src/provider.zig) handle
  reattachment, retrieval, and remote cancellation. See
  [journal recovery](journal.md) for how provider progress relates to an
  admitted model request.
- [`Service.requestRoute` and `backoff`](../src/provider.zig) distinguish a
  fresh attempt from a resume and drive the preview updates. See
  [Controller policy](../../cpi_minimal/README.md#controller-policy) for
  Minimal's retry controls.

## Exchange limits and verification

- [Transport limits and error handling](../src/responses_transport.zig):
  `warnSize`, `connect_timeout`, `Deadline`, `retryAfterMilliseconds`, and
  `remoteResponse`. For the per-exchange deadline, see `live_deadline` and
  `fixture_deadline` in [provider dispatch](../src/provider.zig).
- [Root build](../../../build.zig): `test-provider` selects the
  [agent provider test target](../build.zig). See
  [provider tests](../src/provider_tests.zig) and
  [transport tests](../src/responses_transport_tests.zig) for fixture coverage.
