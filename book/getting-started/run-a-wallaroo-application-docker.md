# Run a Wallaroo Application in Docker

In this section, we're going to run an example Wallaroo application in Docker. By the time you are finished, you'll have validated that your Docker environment is set up and working correctly.

There's a couple Wallaroo support applications that you'll be interacting with for the first time:

- Our Metrics UI that allows you to monitor the performance and health of your applications.
- Giles receiver is designed to capture TCP output from Wallaroo applications.
- Giles sender is used to send test data into Wallaroo applications over TCP.
- Machida, our program for running Wallaroo Python applications.

You're going to set up our "Celsius to Fahrenheit" example application. Giles sender will be used to pump data into the application. Giles receiver will receive the output and our Metrics UI will be running so you can observe the overall performance.

The Metrics UI process will be run in the background. The other three processes (receiver, sender, and Wallaroo) will run in the foreground. We recommend that you run each process in a separate terminal.

NOTE: You might need to run Docker commands with sudo depending on how you set up Docker.

Let's get started!

## Terminal 1, Start the Wallaroo Docker container

```bash
docker run --rm -it --port 4000:4000 --name wally wallaroo-labs-docker-wallaroolabs.bintray.io/first-install/wallaroo:fbdeece
```

We'll be naming our Docker container `wally` so we can access it with convenience and we'll be exposing port 4000 so we can view the Metrics UI. This shell must remain running in order for the container to be kept alive.

Note: For each additional shell needed, run the following command:

```bash
docker exec -it wally bash
```

## Terminal 2, Start the Metrics UI

To start the Metrics UI run:

```bash
metrics_reporter_ui start
```

You can verify it started up correctly by visiting [http://localhost:4000](http://localhost:4000).

If you need to restart the UI, run:

```bash
metrics_reporter_ui restart
```

When it's time to stop the UI, run:

```bash
metrics_reporter_ui stop
```

If you need to start the UI after stopping it, run:

```bash
metrics_reporter_ui start
```

## Terminal 3, Run Giles Receiver

We'll use Giles Receiver to listen for data from our Wallaroo application.

```bash
receiver --listen 127.0.0.1:5555 --no-write --ponythreads=1 --ponynoblock
```

You should see the `Listening for data` that indicates that Giles receiver is running.

## Terminal 4, Run the "Celsius to Fahrenheit" Application

First, we'll need to get to the python Celsius example directory with the following command:

```bash
cd /src/wallaroo/examples/python/celsius
```


Now that we are in the proper directory, and the metrics UI and a data receiver are up and running, we can run the application itself by executing the following command:

```bash
machida --application-module celsius --in 127.0.0.1:7000 \
  --out 127.0.0.1:5555 --metrics 127.0.0.1:5001 --control 127.0.0.1:6000 \
  --data 127.0.0.1:6001 --name worker-name --external 127.0.0.1:5050 \
  --cluster-initializer --ponythreads=1 --ponynoblock
```

This tells the "Celsius to Fahrenheit" application that it should listen on port `7000` for incoming data, write outgoing data to port `5555`, and send metrics data to port `5001`.

## Terminal 5

### Sending Data with Giles Sender

We will be sending in 25,000,000 messages using a pre-generated data file. The data file will be repeatedly sent via Giles Sender until we reach 25,000,000 messages.

You will now be able to start the `sender` with the following command:

```bash
sender --host 127.0.0.1:7000 --messages 25000000 --binary --batch-size 300 \
  --repeat --no-write --msg-size 8 --ponythreads=1 --ponynoblock \
  --file /src/wallaroo/examples/python/celsius/celsius.msg
```

If the sender is working correctly, you should see `Connected` printed to the screen. If you see that, you can be assured that we are now sending data into our example application.

## Check Out Some Metrics

### First Look

Once the sender has successfully connected, if you [visit the Metrics UI](http://localhost:4000) the landing page should show you that the "Celsius to Fahrenheit" application has successfully connected.

![Landing Page](/book/metrics/images/landing-page.png)

If your landing page resembles the one above, the "Celsius to Fahrenheit" application has successfully connected to the Metrics UI.

Now, let's have a look at some metrics. By clicking on the "Celsius to Fahrenheit" link, you'll be taken to the "Application Dashboard" page. On this page you should see metric stats for the following:

- a single pipeline: `Celsius Conversion`
- a single worker: `Initializer`
- three computations: `Add32`, `Decode Time in TCP Source`, `Multiply by 1.8`

![Application Dashboard Page](/book/metrics/images/application-dashboard-page.png)

You'll see the metric stats update as data continues to be processed in our application.

You can then click into one of the elements within a category, to get to a detailed metrics page for that element. If we were to click into the `Add32` computation, we'll be taken to this page:

![Computation Detailed Metrics page](/book/metrics/images/computation-detailed-metrics-page.png)

Feel free to click around and get a feel for how the Metrics UI is setup and how it is used to monitor a running Wallaroo application. If you'd like a deeper dive into the Metrics UI, have a look at our [Monitoring Metrics with the Monitoring Hub](/book/metrics/metrics-ui.md) section.

## Shutdown

### Terminal 6, Cluster Shutdown

You can shut down the cluster with this command once processing has finished:

```bash
cluster_shutdown 127.0.0.1:5050
```

You can shut down Giles Sender and Giles Receiver by pressing Ctrl-c from their respective shells.

You can shut down the Metrics UI with the following command:

```bash
metrics_reporter_ui stop
```

### Wallaroo Container

To shut down the Wallaroo container, press Ctrl-d from Terminal 1. If you hadn't already disconnected from the other shells, this command will close all those sessions as well.
