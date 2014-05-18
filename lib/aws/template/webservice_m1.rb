require "aws/template/webservice_m1/version"

module AWS
  class Template
    class WebserviceM1 < Template
      def initialize(override_path)
        super
        @template_path = File.expand_path(File.join(File.dirname(__FILE__), "..", "..", "..", "config", "aws-template.json"))
      end

      protected
      def execute_apply(config, *args)
        vpc.create(config["vpc_name"], config["vpc_cidr"])
        config["vpc_id"] = vpc.aws_instance.id

        subnet.create(vpc.aws_instance, config["subnets"])
        # create cidr -> subnet_id maps (for vagrant)
        config["subnets"]["cidr"] = {}
        subnet.aws_instance.each do |s|
          config["subnets"]["cidr"][s.cidr_block] = s.id
        end

        igw.create(vpc.aws_instance, config["igw_name"])
        config["igw_id"] = igw.aws_instance.id

        route.create(vpc.aws_instance, igw.aws_instance, config["subnets"], "route-main", "route-public", "0.0.0.0/0")

        security_group.create(vpc.aws_instance, config["security_groups"], config["security_groups_ssh_source"])
        security_group.aws_instance.each do |name, s|
          config["security_groups"][name]["id"] = s.id
        end

        key_pair.create(config["key_pair_name"], File.expand_path(config["key_pair_local_path"]))

        load_balancer.create(config["load_balancers"], config["subnets"], config["security_groups"])
        load_balancer.aws_instance.each do |lb_name, lb|
          config["load_balancers"][lb_name]["dns_name"] = lb.dns_name
        end

        # temorary update for lauching instance
        store(config, @customized_path)

        launch_proc = args.shift
        ec2.create(config["ec2_gateway_name"], launch_proc)
        eni = ec2.eni(config["ec2_gateway_name"])
        if eni.nil?
          log("warning: no ENIs in gateway instance, skip creating routes")
        end

        route.associate(vpc.aws_instance, eni, "route-main", "0.0.0.0/0")

        r53.create(config["zone_name"])
        r53.add_a_record(config["zone_name"], config["ec2_gateway_zone_name"], eni.elastic_ip.public_ip)
        config["load_balancers"].each do |lb_name, lb_config|
          r53.add_a_record_lb(config["zone_name"], load_balancer.aws_instance, lb_name, lb_config)
        end
      end

      def execute_destroy(config, *args)
        shutdown_proc = args.shift
        options = args.shift

        # ec2.destroy(shutdown_proc)

        r53.delete_a_record(config["zone_name"], config["ec2_gateway_zone_name"])
        config["load_balancers"].each do |lb_name, lb_config|
          r53.delete_a_record_lb(config["zone_name"], lb_name, lb_config)
        end
        r53.destroy(config["zone_name"]) if options[:destroy_zone]

        load_balancer.destroy(config["load_balancers"])
        key_pair.destroy(config["key_pair_name"]) if options[:destroy_key_pair]
        security_group.destroy(config["security_groups"])

        route.destroy(config["vpc_name"], ["route-main", "route-public"])
        igw.destroy(config["vpc_name"], config["igw_name"])
        subnet.destroy(config["vpc_name"], config["subnets"])
        vpc.destroy(config["vpc_name"])
      end

    end
  end
end
