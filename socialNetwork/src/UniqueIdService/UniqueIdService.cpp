/*
 * 64-bit Unique Id Generator
 *
 * ------------------------------------------------------------------------
 * |0| 11 bit machine ID |      40-bit timestamp         | 12-bit counter |
 * ------------------------------------------------------------------------
 *
 * 11-bit machine Id code by hasing the MAC address
 * 40-bit UNIX timestamp in millisecond precision with custom epoch
 * 12 bit counter which increases monotonically on single process
 *
 */

#include <signal.h>
#include <thrift/protocol/TBinaryProtocol.h>
#include <thrift/server/TThreadedServer.h>
#include <thrift/transport/TBufferTransports.h>
#include <thrift/transport/TServerSocket.h>

#include "../utils.h"
#include "../utils_thrift.h"
#include "UniqueIdHandler.h"
#include "../gordion/Gordion.h"

using apache::thrift::protocol::TBinaryProtocolFactory;
using apache::thrift::server::TThreadedServer;
using apache::thrift::transport::TFramedTransportFactory;
using apache::thrift::transport::TServerSocket;
using namespace social_network;

void sigintHandler(int sig) { exit(EXIT_SUCCESS); }

int main(int argc, char *argv[]) {
  signal(SIGINT, sigintHandler);
  init_logger();
  SetUpTracer("config/jaeger-config.yml", "unique-id-service");

  json config_json;
  if (load_config_file("config/service-config.json", &config_json) != 0) {
    exit(EXIT_FAILURE);
  }

  int port = config_json["unique-id-service"]["port"];
  std::string netif = config_json["unique-id-service"]["netif"];

  std::string machine_id = GetMachineId(netif);
  if (machine_id == "") {
    exit(EXIT_FAILURE);
  }
  LOG(info) << "machine_id = " << machine_id;

  std::mutex thread_lock;
  // Phase J2: the receive-timestamp server socket (SO_TIMESTAMPNS on accepted connections; Lat starts at the segment's
  // arrival) unless SSL is configured, in which case the stock socket
  std::shared_ptr<TServerSocket> server_socket =
      config_json["ssl"]["enabled"] ? get_server_socket(config_json, "0.0.0.0", port)
                                    : std::static_pointer_cast<TServerSocket>(std::make_shared<gordion::TServerSocketTS>("0.0.0.0", port));
  // Addendum F: gordion recorder on the processor (thread = request; no downstream call)
  TThreadedServer server(
      gordion::Attach(std::make_shared<UniqueIdServiceProcessor>(
          std::make_shared<UniqueIdHandler>(&thread_lock, machine_id)), "unique-id", {"ComposeUniqueId"}),
      server_socket,
      std::make_shared<TFramedTransportFactory>(),
      std::make_shared<TBinaryProtocolFactory>());

  LOG(info) << "Starting the unique-id-service server ...";
  server.serve();
}
