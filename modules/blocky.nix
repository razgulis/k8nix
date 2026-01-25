{ config, lib, pkgs, ... }:

{
  services.blocky = {
    enable = true;
    settings = {
      port = 53;
      upstream.default = [
        "1.1.1.1"
        "https://one.one.one.one/dns-query"
      ];
      bootstrapDns = {
        upstream = "https://one.one.one.one/dns-query";
        ips = [ "1.1.1.1" "1.0.0.1" ];
      };
      blocking = {
        blackLists = {
          ads = [ "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts" ];
          special = [ "/etc/blocky/custom-block-list.txt" ];
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
