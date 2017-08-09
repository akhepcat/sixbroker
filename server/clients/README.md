The 'clients'  directory is used for keeping the textual database files that hold each registered endpoint's public key.

The server script will iterate through all of the client config files to build the final server configuration file.
It will also use each of the client 'names'  as an index to the  parent 'clients.conf'  which holds additional
nonstandard configuration data, such as IPv6 tunneling information.
