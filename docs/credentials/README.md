# Credentials a workload can use and never read

[Credential substitution](../credential-substitution.md) is the reference: bindings, where the
value comes from, what the guest sees, what happens to each request, the limits, and the external
interceptor. `SKILL.md` is the agent procedure, with scripts that prove on your own host that the
value stays out of the machine. This page records what the procedure measured beside the
reference.

## The value is the one `machine start` saw

Measured on v1.18.2: the value used is the one in the environment of the `machine start` that
launched the machine, since the interceptor runs in that process. Unsetting the variable for a
later `machine exec` did not stop substitution, and starting the machine with it unset gave
`502 smolvm credentials: credential unavailable`. So a value from the host environment rotates with
a restart, and one that must rotate in place belongs in a file reference.

## The bound host has to present a publicly trusted certificate

The interceptor checks the bound host's certificate against public roots and takes no root of
your own. Measured on v1.22.2 against a local HTTPS server with a self-signed certificate for the
bound name: the containment checks all passed, and the request carrying the placeholder came back
`502 smolvm credentials: upstream request failed`, with nothing reaching the server. A test endpoint
for this feature needs a certificate a public CA issued.
