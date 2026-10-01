# Access

How to log in to each service. With the Lima VM the services are on
`127.0.0.1` on your computer and the tasks do most of it. On a Debian host
they are on the host's own addresses and you run the commands there.

Both HTTPS services use self-signed certificates. A browser warns once per
service; accept the certificate.

## Incus web UI

```sh
task incus-dash
```

This opens the web UI in your browser, already logged in. It works through
the `incus` client that the Brewfile installs:

1. The script adds a remote named `incusdev` to your incus client, with a
   one-time token from the VM. The client makes its own certificate.
2. It runs `incus webui incusdev:`. The client serves the web UI on a local
   address and logs in with its certificate, so the browser needs none.
3. The client stays in the background, because the page works through it.
   The session lasts until `task down` or `task destroy`.

The remote `incusdev` belongs to this project. The script replaces it when it
stops working, which happens when the VM is deleted and made again, and
`task destroy` removes it.

On a Debian host, do the same by hand from the computer you browse on:

```sh
sudo incus config trust add laptop                     # on the host: a token
incus remote add myhost https://<host>:8443 --token <token>
incus webui myhost:
```

## Incus API, with the incus client

After the first `task incus-dash`, the remote is there:

```sh
incus list incusdev:
incus remote switch incusdev     # make it the default
```

Every `incus` command also works inside the VM, with no remote:

```sh
limactl shell incusdev incus list
```

## Ceph dashboard

`task ceph-dash` opens `https://127.0.0.1:8444`. Log in as `admin` with the
password `admin@ceph123`; a URL cannot carry that login. The password is the
default of the ceph-aio image. It is fine on a loopback address and nowhere
else.

## S3 API

The install creates one S3 user, `incusdev`. Ceph makes its keys.
`task s3-credentials` prints them with the endpoint, as environment variables:

```sh
eval "$(task s3-credentials)"
aws s3 mb s3://test
aws s3 cp README.md s3://test/
aws s3 ls s3://test
```

The variables are `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
`AWS_ENDPOINT_URL` and `AWS_DEFAULT_REGION`. The AWS CLI v2 and the AWS SDKs
read all four. Other clients take the same values in their own settings; use
path-style addressing, since there is no DNS name per bucket.

On a Debian host, read the keys and make more users with `radosgw-admin`:

```sh
sudo radosgw-admin user info --uid incusdev
sudo radosgw-admin user create --uid alice --display-name Alice
```

## A port is already in use

With Lima, the ports 8443, 8444 and 8000 must be free on `127.0.0.1`. If
another program holds one, Lima cannot forward it, and `task up` lists the
service as `down` or shows the other program. Stop that program and run
`task down` and `task up`.
