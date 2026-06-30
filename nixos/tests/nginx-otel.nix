{
  name = "nginx-otel";

  nodes.machine =
    { pkgs, ... }:
    {
      services.nginx = {
        enable = true;
        additionalModules = [ pkgs.nginxModules.otel ];
        commonHttpConfig = ''
          otel_exporter {
            endpoint localhost:4317;
          }
          otel_service_name "nginx-test";
          otel_trace on;
        '';
        virtualHosts."localhost".locations."/".extraConfig = ''
          otel_trace_context propagate;
          otel_span_name "handle";
          return 200 "otel-ok";
        '';
      };
    };

  testScript =
    { nodes, ... }:
    let
      cfg = nodes.machine.services.nginx;
    in
    ''
      machine.wait_for_unit("nginx")
      machine.wait_for_open_port(80)

      # The build produced the module and listed it in the load_module snippet.
      machine.succeed("test -e ${cfg.package}/modules/ngx_otel_module.so")
      machine.succeed("grep -F ngx_otel_module.so ${cfg.package}/etc/nginx/dynamic-modules.conf")

      # The otel directives only validate once nginx has dlopen'd the module.
      response = machine.wait_until_succeeds("curl -fsS http://127.0.0.1/")
      assert "otel-ok" in response, response
    '';
}
