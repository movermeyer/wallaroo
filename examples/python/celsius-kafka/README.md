# Celsius

## About The Application

This is an example of a stateless Python application that takes a floating point Celsius value from Kafka and sends out a floating point Fahrenheit value to Kafka.

### Input and Output

The inputs and outputs of the "Celsius Kafka" application are binary 32-bit floats. Here's an example message, written as a Python string:

```
"\x42\x48\x00\x00"
```

`\x42\x48\x00\x00` -- four bytes representing the 32-bit float `50.0`


### Processing

The `Decoder`'s `decode(...)` method creates a float from the value represented by the payload. The float value is then sent to the `Multiply` computation where it is multiplied by `1.8`, and the result of that computation is sent to the `Add` computation where `32` is added to it. The resulting float is then sent to the `Encoder`, which converts it to an outgoing sequence of bytes.

## Running Celsius Kafka

In order to run the application you will need Machida and the Cluster Shutdown tool. To build them, please see the [Linux](/book/getting-started/linux-setup.md) or [Mac OS](/book/getting-started/macos-setup.md) setup instructions. Alternatively, they could be run in Docker, please see the [Docker](/book/getting-started/docker-setup.md) setup instructions.

Note: If running in Docker, the relative paths are not necessary for binaries as they are all bound to the PATH within the container. You will not need to set the `PATH` variable and you'd only need to append the current directory to `PYTHONPATH`.

You will also need access to a Kafka cluster. This example assumes that there is a Kafka broker listening on port `9092` on `127.0.0.1`.

You will need three separate shells to run this application. Open each shell and go to the `examples/python/celsius-kafka` directory.

### Shell 1

#### Start kafka and create the `test-in` and `test-out` topics

You need kafka running for this example. Ideally you should go to the kafka website (https://kafka.apache.org/) to properly configure kafka for your system and needs. However, the following is a quick/easy way to get kafka running for this example:

This requires `docker-compose`:

Ubuntu:

```bash
sudo curl -L https://github.com/docker/compose/releases/download/1.15.0/docker-compose-`uname -s`-`uname -m` -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
```

OSX: Docker compose is already included as part of Docker for Mac.


NOTE: You might need to run with sudo depending on how you set up Docker.

Clone local-kafka-cluster project and run it:

```bash
cd /tmp
git clone https://github.com/effata/local-kafka-cluster
cd local-kafka-cluster
./cluster up 1 # change 1 to however many brokers are desired to be started
docker exec -it local_kafka_1_1 /kafka/bin/kafka-topics.sh --zookeeper \
  zookeeper:2181 --create --partitions 4 --topic test-in --replication-factor \
  1 # to create a test-in topic; change arguments as desired
docker exec -it local_kafka_1_1 /kafka/bin/kafka-topics.sh --zookeeper \
  zookeeper:2181 --create --partitions 4 --topic test-out --replication-factor \
  1 # to create a test-out topic; change arguments as desired
```

#### Set up a listener to monitor the Kafka topic to which you would the application to publish results. We usually use `kafkacat`.

`kafkacat` can be installed via:

Ubuntu:

```bash
sudo apt-get install kafkacat
```

MacOS:

```bash
brew install kafkacat
```

To run `kafkacat` to listen to the `test-out` topic:

```bash
kafkacat -C -b 127.0.0.1:9092 -t test-out > celsius.out
```

### Shell 2

Set `PYTHONPATH` to refer to the current directory (where `celsius.py` is) and the `machida` directory (where `wallaroo.py` is). Set `PATH` to refer to the directory that contains the `machida` executable. Assuming you installed Machida according to the tutorial instructions you would do:

```bash
export PYTHONPATH="$PYTHONPATH:.:$HOME/wallaroo-tutorial/wallaroo/machida"
export PATH="$PATH:$HOME/wallaroo-tutorial/wallaroo/machida/build"
```

Run `machida` with `--application-module celsius`:

```bash
machida --application-module celsius \
  --kafka_source_topic test-in --kafka_source_brokers 127.0.0.1:9092 \
  --kafka_sink_topic test-out --kafka_sink_brokers 127.0.0.1:9092 \
  --kafka_sink_max_message_size 100000 --kafka_sink_max_produce_buffer_ms 10 \
  --metrics 127.0.0.1:5001 --control 127.0.0.1:12500 --data 127.0.0.1:12501 \
  --external 127.0.0.1:5050 --cluster-initializer --ponythreads=1 \
  --ponynoblock
```

`kafka_sink_max_message_size` controls maximum size of message sent to kafka in a single produce request. Kafka will return errors if this is bigger than server is configured to accept.

`kafka_sink_max_produce_buffer_ms` controls maximum time (in ms) to buffer messages before sending to kafka. Either don't specify it or set it to `0` to disable batching on produce.

### Shell 3

Send data into Kafka. Again, we use `kafakcat`.

Run the following and then type at least 4 characters on each line and hit enter to send in data (only first 4 characters are used/interpreted as a float; the application will throw an error and possibly segfault if less than 4 characters are sent in):

```bash
kafkacat -P -b 127.0.0.1:9092 -t test-in
```

Note: You can use `ctrl-d` to exit `kafkacat`

## Reading the Output

The output data will be in the file that `kafkacat` is writing to in shell 1. You can read the output data with the following code:

```python
import struct


with open('celsius.out', 'rb') as f:
    while True:
        try:
            print struct.unpack('>f', f.read(4))
        except:
            break
```

## Shutdown

To shut down the cluster, you will need to use the `cluster_shutdown` tool.

```bash
../../../utils/cluster_shutdown/cluster_shutdown 127.0.0.1:5050
```

You can shut down the kafkacat producer by pressing Ctrl-d from its shell.

You can shut down the kafkacat consumer by pressing Ctrl-c from its shell.

### Stop kafka

NOTE: You might need to run with sudo depending on how you set up Docker.

If you followed the commands earlier to start kafka you can stop it by running:

```bash
cd /tmp/local-kafka-cluster
./cluster down # shut down cluster
```
