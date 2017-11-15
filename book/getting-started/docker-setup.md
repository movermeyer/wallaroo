# Setting Up Your Environment for Wallaroo in Docker

To get you up and running quickly with Wallaroo, we've provided a Docker image which includes Wallaroo and related tools needed to run and modify a few example applications.

## Installing Docker

### MacOS

There are [instructions](https://docs.docker.com/docker-for-mac/) for getting Docker up and running on MacOS on the [Docker website](https://docs.docker.com/docker-for-mac/).  We recommend the 'Standard' version of the 'Docker for Mac' package.

Installing Docker will result in it running on your machine. After you reboot your machine, that will no longer be the case. In the future, you'll need to have Docker running in order to use a variety of commands in this book. We suggest that you [set up Docker to boot automatically](https://docs.docker.com/docker-for-mac/#general).

### Linux Ubuntu

There are [instructions](https://docs.docker.com/engine/installation/linux/ubuntu/) for getting Docker up and running on Ubuntu on the [Docker website](https://docs.docker.com/engine/installation/linux/ubuntu/).

Installing Docker will result in it running on your machine. After you reboot your machine, that will no longer be the case. In the future, you'll need to have Docker running in order to use a variety of commands in this book. We suggest that you [set up Docker to boot automatically](https://docs.docker.com/engine/installation/linux/linux-postinstall/#configure-docker-to-start-on-boot).

All of the Docker commands throughout the rest of this manual assume that you have permission to run Docker commands as a non-root user. Follow the [Manage Docker as a non-root user](https://docs.docker.com/engine/installation/linux/linux-postinstall/#manage-docker-as-a-non-root-user) instructions to set that up. If you don't want to allow a non-root user to run Docker commands, you'll need to run `sudo docker` anywhere you see `docker` for a command.

## Pull the official Wallaroo image from [Bintray](https://bintray.com/wallaroo-labs/wallaroolabs/first-install%3Awallaroo):

```bash
docker pull wallaroo-labs-docker-wallaroolabs.bintray.io/first-install/wallaroo:fbdeece
```

## What's Included

### Machida

Machida is the program that runs Wallaroo Python applications.

### Giles Sender

Giles Sender is used to supply data to Wallaroo applications over TCP.

### Giles Receiver

Giles Receiver receives data from Wallaroo over TCP.

### Cluster Shutdown tool

The Cluster Shutdown tool is used to tell the cluster to shut down cleanly.

### Metrics UI

The Metrics UI is used to receive and display metrics for running Wallaroo applications.

## Conclusion

Awesome! All set. Time to try running your first Wallaroo application in Docker.
