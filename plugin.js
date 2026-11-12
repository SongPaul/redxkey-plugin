function createPlugin(host) {
  const service = "57d25503-8ae4-47b1-9631-d10dd513a095";
  const weightCharacteristic = "c8d1d213-e353-4c68-a9f6-91eb50b95f8c";
  const startCharacteristic = "2a92b06a-461e-4ea3-b294-5d1a7e351825";
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  const notSent = ["stale_session", "permission_denied", "attribute_unavailable", "resource_limit"];
  const pauseMs = 300;
  let writeMode = "withResponse";

  const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

  function byteBase64(b) {
    return alphabet[b >> 2] + alphabet[(b & 3) << 4] + "==";
  }

  function tenthsFrom(grams) {
    const tenths = Math.round(Number(grams) * 10);
    if (!Number.isFinite(tenths) || tenths < 1 || tenths > 255) {
      throw new Error("grams must be from 0.1 to 25.5");
    }
    return tenths;
  }

  function writeModeFrom(settings) {
    return settings && settings.writeMode === "withoutResponse" ? "withoutResponse" : "withResponse";
  }

  function write(gatt, characteristic, data) {
    return writeMode === "withoutResponse"
      ? gatt.writeWithoutResponse(service, characteristic, data)
      : gatt.writeWithResponse(service, characteristic, data);
  }

  function errorText(error) {
    return String((error && error.message) || error);
  }

  return {
    id: "redxkey.reaplugin",
    onLoad(settings) {
      writeMode = writeModeFrom(settings);
      return host.devices.bindDriver("module", {
        create() {
          const module = {session: null, busy: false, lastGrams: 0, count: 0};

          function publish(state) {
            if (!module.session) return Promise.resolve();
            return module.session.publish({state, lastGrams: module.lastGrams, dispenseCount: module.count})
              .catch(() => {});
          }

          async function dispense(grams) {
            const tenths = tenthsFrom(grams);
            const session = module.session;
            if (!session) throw new Error("RedxKey module is not connected");
            if (module.busy) throw new Error("RedxKey module is already dispensing");
            module.busy = true;
            let startSent = false;
            try {
              await publish("dispensing");
              await write(session.gatt, weightCharacteristic, byteBase64(tenths));
              await sleep(pauseMs);
              startSent = true;
              await write(session.gatt, startCharacteristic, "AQ==");
              await sleep(pauseMs);
              module.lastGrams = tenths / 10;
              module.count += 1;
              await publish("idle");
              return {result: "ok", grams: tenths / 10};
            } catch (error) {
              const uncertain = startSent && !notSent.includes(error && error.code);
              await publish(uncertain ? "uncertain" : "error");
              return {result: uncertain ? "uncertain" : "failed", grams: tenths / 10, error: errorText(error)};
            } finally {
              module.busy = false;
            }
          }

          return {
            vendor: "RedxKey",
            dataChannels: [
              {key: "state", type: "string"},
              {key: "lastGrams", type: "number", unit: "g"},
              {key: "dispenseCount", type: "integer"}
            ],
            commands: [{
              id: "dispense",
              name: "Dispense",
              paramsSchema: {
                type: "object",
                properties: {grams: {type: "number", minimum: 0.1, maximum: 25.5}},
                required: ["grams"]
              },
              resultsSchema: {
                type: "object",
                properties: {
                  result: {type: "string", enum: ["ok", "failed", "uncertain"]},
                  grams: {type: "number"},
                  error: {type: "string"}
                }
              }
            }],
            async connect(session) {
              const services = await session.gatt.discoverServices();
              if (!services.includes(service)) throw new Error("RedxKey service unavailable");
              session.gatt.onDisconnect(() => {
                if (module.session === session) module.session = null;
              });
              module.session = session;
              await publish("idle");
            },
            disconnect() {
              module.session = null;
            },
            async execute(command) {
              if (command.commandId !== "dispense") {
                throw new Error("Unknown RedxKey command: " + command.commandId);
              }
              return dispense(command.params && command.params.grams);
            }
          };
        }
      });
    }
  };
}
