
The 'private'  directory holds the server public and private keys.

the permissions should be mostly restrictive on the directory:
0711 - so that the public key can be read by the client registration system.

the private key should be 0600 - only the WireGuard service accesses it.

the public key should be 0644 - as it needs to be read by the client registration system,
  and is, of course, publicly distributed


    \# dir -a /etc/wireguard/private
    total 16
    drwx--x--x 2 root root 4096 Aug  9 08:22 ./
    drwxr-xr-x 5 root root 4096 Aug  9 08:21 ../
    -rw------- 1 root root   45 Jul 20 10:49 sixbroker.privatekey
    -rw-r--r-- 1 root root   45 Jul 20 10:49 sixbroker.publickey


