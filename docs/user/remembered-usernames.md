# Remember sign-in usernames

On Linux and macOS Clients, an administrator can opt in through
`/etc/plank/client.conf`:

```ini
[authentication]
remember_username = true
```

The default is `false`. On macOS, create the root-owned configuration file if
it does not exist. Restart the Client after changing policy. There is no
user-facing preference for this administrator-controlled option.

The Client remembers the last successful sign-in username separately for each
bookmark in that local OS user's existing bookmark settings. On opening the
sign-in dialog, it prefills the editable username and focuses the empty password
field. It never automatically submits a login. Failed sign-ins and cancellations
do not replace the remembered name; the name is saved only after the normal
authenticated connection preparation completes.

Passwords, session tokens and the existing in-memory reconnect credentials are
not saved by this feature. The remembered name is ordinary local preference
data, not an encrypted secret. Avoid enabling it on shared OS accounts if showing
the previous user's login name is undesirable.

Deleting a bookmark or changing its destination clears its saved username.
Changing its nickname or display settings does not. Setting the policy to
`false`, omitting it, or using an invalid value disables the feature. On the next
Client startup, saved names are removed from both primary and backup bookmark
entries without removing other settings.

This option is unrelated to the Linux Host's `security.publish_session_user`
setting. A Host's public In Session username is never used to prefill a login.
Host authentication, takeover and desktop-ownership rules are unchanged.
