# Account Usage

Remaining usage for the active coding account beside the model controls in Zeron's bottom bar. It follows the open chat's provider and device; a new chat keeps the last provider. Choose a provider explicitly in **Settings → Account Usage** if needed.

Shows up to two reported quota windows as percentages remaining, such as session and week. Hover for a native glass panel with remaining-quota meters, reset times, plan, and when the data was fetched. Click to refresh, or use **Account Usage → Refresh account usage** from the menu bar. Automatic refresh defaults to five minutes while Zeron is visible. There are no notifications.

Cached or expired data is marked **Cached** with a status dot. Low remaining quota turns amber, then red. Missing limits, missing sign-ins, and ambiguous active accounts are never shown as 0% or 100%. This displays account quotas, separate from the chat's context-window indicator.

Uses Python 3 and Zeron's authenticated local IPC. It reads the chat registry only to select the provider/device, then asks Zeron for its existing account usage view. It does not read transcripts, expose email addresses or credentials, change accounts, purchase credits, or send data to a separate external service. Forced refresh asks Zeron to refresh its provider usage probes, subject to Zeron's existing rate limits and backoff.
