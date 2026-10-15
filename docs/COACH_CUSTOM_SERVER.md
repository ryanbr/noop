# Coach with LiteLLM or another OpenAI-compatible server

1. Open **Coach** settings and select the **Custom** provider.
2. Enter the server's OpenAI-compatible base URL, ending in `/v1`, then enter the virtual key if the
   server requires authentication and choose **Connect**.
3. Refresh models and choose the model ID returned by the server's `GET /v1/models` endpoint. With
   LiteLLM, use the configured public model name (for example, `noop-coach`), not the upstream
   provider's internal model name.
4. Send a Coach message. Custom chat uses the OpenAI-compatible chat completions endpoint. The saved
   key is sent as a Bearer token unless the Custom provider's alternate header option is selected.

For an iPhone connecting to a server outside the same device, `localhost` points to the iPhone,
not the Mac or server. Use a hostname or address reachable from the phone. iOS App Transport
Security requires HTTPS for ordinary remote hosts; a trusted private-network HTTP URL may be used
for local development where the app's private-network HTTP policy permits it. A Tailscale Serve
HTTPS listener can front a private LiteLLM HTTP service so the phone uses an HTTPS URL while the
origin remains on the tailnet. Use a dedicated, least-privilege LiteLLM virtual key and limit it to
the model Coach needs. Never put a key in the URL or paste it into logs or source control.

Custom provider keys and settings are local to the NOOP app. Coach requests go directly to the
configured server; NOOP does not proxy them. Chat text and any enabled metric summary are sent to
that server according to the Coach data-access setting. See the Coach section in
[`PRIVACY_SECURITY.md`](PRIVACY_SECURITY.md#11a-the-ai-coach-optional-off-by-default-bring-your-own-key).
