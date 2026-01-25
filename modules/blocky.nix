{ config, lib, pkgs, ... }:

{
  # `systemd-resolved` binds to 127.0.0.53:53 by default, which prevents Blocky
  # from binding to :53. Keep resolved for mDNS, but disable the DNS stub on
  # hosts that run Blocky.
  services.resolved.settings.Resolve.DNSStubListener = lib.mkDefault "no";

  services.blocky = {
    enable = true;
    settings = {
      ports.dns = 53;
      upstreams.groups.default = [
        "tcp+udp:1.1.1.1"
        "tcp+udp:1.0.0.1"
      ];
      bootstrapDns = [
        {
          upstream = "tcp+udp:1.1.1.1";
          ips = [ "1.1.1.1" "1.0.0.1" ];
        }
      ];
      blocking = {
        denylists = {
          ads = [ "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts" ];
          special = [ "file:///etc/blocky/custom-block-list.txt" ];
        };
        clientGroupsBlock = {
          default = [ "ads" "special" ];
        };
      };
      caching = {
        prefetching = true;
        minTime = "5m";
        maxTime = "30m";
      };
    };
  };

  environment.etc."blocky/custom-block-list.txt".source =
    ./blocky/custom-block-list.txt;
}
