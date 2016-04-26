require 'cfndsl'

CloudFormation {

  # Template metadata
  AWSTemplateFormatVersion "2010-09-09"
  Description "#{application_name} - VPC v#{cf_version}"

  # Parameters
  Parameter("EnvironmentType"){ Type 'String' }
  Parameter("EnvironmentName"){ Type 'String' }
  Parameter("StackOctet") {
    Type 'String'
    AllowedPattern '[0-9]*'
  }

  availability_zones.each do |az|
  Parameter("Nat#{az}EIPAllocationId") { Type 'String' }
  end

  # Global mappings
  Mapping('EnvironmentType', Mappings['EnvironmentType'])
  Mapping('AccountId', AccountId)
  Mapping('BastionAMI', bastionAMI)

  availability_zones.each do |az|
  Condition("Nat#{az}EIPRequired", FnEquals(Ref("Nat#{az}EIPAllocationId"), 'dynamic'))
  end

  # Resources
  Resource("VPC") {
    Type 'AWS::EC2::VPC'
    Property('CidrBlock', FnJoin( "", [ FnFindInMap('EnvironmentType', Ref('EnvironmentType'),'NetworkPrefix'),".", Ref('StackOctet'), ".0.0/", FnFindInMap('EnvironmentType', Ref('EnvironmentType'),'StackMask') ] ))
    Property('EnableDnsSupport', true)
    Property('EnableDnsHostnames', true)
  }

  Resource("HostedZone") {
    Type 'AWS::Route53::HostedZone'
    Property('Name', FnJoin('.', [ Ref('EnvironmentName'), FnFindInMap('AccountId', Ref('AWS::AccountId'),'DnsDomain') ]) )
  }

  availability_zones.each do |az|
    Resource("SubnetPublic#{az}") {
      Type 'AWS::EC2::Subnet'
      Property('VpcId', Ref('VPC'))
      Property('CidrBlock', FnJoin( "", [ FnFindInMap('EnvironmentType', Ref('EnvironmentType'),'NetworkPrefix'), ".", Ref('StackOctet'), ".", vpc["SubnetOctet#{az}"], ".0/", FnFindInMap('EnvironmentType', Ref('EnvironmentType'),'SubnetMask') ] ))
      Property('AvailabilityZone', FnSelect(azId[az], FnGetAZs(Ref( "AWS::Region" )) ))
      Property('Tags',[
        {
          Key: 'Name', Value: FnJoin( "", [ Ref('EnvironmentName'), "-public#{az}"])
        }
      ])
    }
  end

  Resource("InternetGateway") {
    Type 'AWS::EC2::InternetGateway'
  }

  Resource("AttachGateway") {
    Type 'AWS::EC2::VPCGatewayAttachment'
    Property('VpcId', Ref('VPC'))
    Property('InternetGatewayId', Ref('InternetGateway'))
  }

  availability_zones.each do |az|
    Resource("NatIPAddress#{az}") {
      DependsOn ["AttachGateway"]
      Type 'AWS::EC2::EIP'
      Condition("Nat#{az}EIPRequired")
      Property('Domain', 'vpc')
    }
  end

  Resource("BastionIPAddress") {
    DependsOn ["AttachGateway"]
    Type 'AWS::EC2::EIP'
    Property('Domain', 'vpc')
  }

  availability_zones.each do |az|
    Resource("NatGateway#{az}") {
      Type 'AWS::EC2::NatGateway'
      Property('AllocationId', FnGetAtt("NatIPAddress#{az}",'AllocationId'))
      Property('SubnetId', Ref("SubnetPublic#{az}"))
    }
  end

  Resource("RouteTablePublic") {
    Type 'AWS::EC2::RouteTable'
    Property('VpcId', Ref('VPC'))
    Property('Tags',[
      {
        Key: 'Name', Value: FnJoin( "", [ Ref('EnvironmentName'), "-public"])
      }
    ])
  }

  availability_zones.each do |az|
    Resource("RouteTablePrivate#{az}") {
      Type 'AWS::EC2::RouteTable'
      Property('VpcId', Ref('VPC'))
      Property('Tags',[
        {
          Key: 'Name', Value: FnJoin( "", [ Ref('EnvironmentName'), "-private#{az}"])
        }
      ])
    }
  end

  availability_zones.each do |az|
    Resource("SubnetRouteTableAssociationPublic#{az}") {
      Type 'AWS::EC2::SubnetRouteTableAssociation'
      Property('SubnetId', Ref("SubnetPublic#{az}"))
      Property('RouteTableId', Ref('RouteTablePublic'))
    }
  end

  Resource("PublicRouteOutToInternet") {
    Type 'AWS::EC2::Route'
    DependsOn ["AttachGateway"]
    Property('RouteTableId', Ref("RouteTablePublic"))
    Property('DestinationCidrBlock', '0.0.0.0/0')
    Property('GatewayId',Ref("InternetGateway"))
  }

  Resource("PublicNetworkAcl") {
    Type 'AWS::EC2::NetworkAcl'
    Property('VpcId', Ref('VPC'))
  }

  # Name => RuleNumber, Protocol, RuleAction, Egress, CidrBlock, PortRange From, PortRange To
  acls = {
    InboundHTTPPublicNetworkAclEntry:       ['100','6','allow','false','0.0.0.0/0','80','80'],
    InboundHTTPSPublicNetworkAclEntry:      ['101','6','allow','false','0.0.0.0/0','443','443'],
    InboundSSHPublicNetworkAclEntry:        ['102','6','allow','false','0.0.0.0/0','22','22'],
    InboundNTPPublicNetworkAclEntry:        ['103','17','allow','true','0.0.0.0/0','123','123'],
    InboundEphemeralPublicNetworkAclEntry:  ['104','6','allow','false','0.0.0.0/0','1024','65535'],
    OutboundNetworkAclEntry:                ['105','-1','allow','true','0.0.0.0/0','0','65535']
  }
  acls.each do |alcName,alcProperties|
    Resource(alcName) {
      Type 'AWS::EC2::NetworkAclEntry'
      Property('NetworkAclId', Ref('PublicNetworkAcl'))
      Property('RuleNumber', alcProperties[0])
      Property('Protocol', alcProperties[1])
      Property('RuleAction', alcProperties[2])
      Property('Egress', alcProperties[3])
      Property('CidrBlock', alcProperties[4])
      Property('PortRange',{
        From: alcProperties[5],
        To: alcProperties[6]
      })
    }
  end

  availability_zones.each do |az|
    Resource("SubnetNetworkAclAssociationPublic#{az}") {
      Type 'AWS::EC2::SubnetNetworkAclAssociation'
      Property('SubnetId', Ref("SubnetPublic#{az}"))
      Property('NetworkAclId', Ref('PublicNetworkAcl'))
    }
  end

  Resource("DHCPOptionSet") {
    Type 'AWS::EC2::DHCPOptions'
    Property('DomainName', FnJoin('.', [ Ref('EnvironmentName'), FnFindInMap('AccountId',Ref('AWS::AccountId'),'DnsDomain') ]))
    Property('DomainNameServers', ['AmazonProvidedDNS'])
  }

  Resource("DHCPOptionsAssociation") {
    Type 'AWS::EC2::VPCDHCPOptionsAssociation'
    Property('VpcId', Ref('VPC'))
    Property('DhcpOptionsId', Ref('DHCPOptionSet'))
  }

  rules = []
  opsAccess.each do |ip|
    rules << { IpProtocol: 'tcp', FromPort: '22', ToPort: '22', CidrIp: ip }
    rules << { IpProtocol: 'tcp', FromPort: '80', ToPort: '80', CidrIp: ip }
    rules << { IpProtocol: 'tcp', FromPort: '443', ToPort: '443', CidrIp: ip }
  end

  Resource("SecurityGroupOps") {
    Type 'AWS::EC2::SecurityGroup'
    Property('VpcId', Ref('VPC'))
    Property('GroupDescription', 'Ops External Access')
    Property('SecurityGroupIngress', rules)
  }

  rules = []
  devAccess.each do |ip|
    rules << { IpProtocol: 'tcp', FromPort: '22', ToPort: '22', CidrIp: ip }
    rules << { IpProtocol: 'tcp', FromPort: '80', ToPort: '80', CidrIp: ip }
    rules << { IpProtocol: 'tcp', FromPort: '443', ToPort: '443', CidrIp: ip }
  end

  Resource("SecurityGroupDev") {
    Type 'AWS::EC2::SecurityGroup'
    Property('VpcId', Ref('VPC'))
    Property('GroupDescription', 'Dev Team Access')
    Property('SecurityGroupIngress', rules)
  }

  Resource("SecurityGroupBackplane") {
    Type 'AWS::EC2::SecurityGroup'
    Property('VpcId', Ref('VPC'))
    Property('GroupDescription', 'Backplane SG')
    Property('SecurityGroupIngress', [
      { IpProtocol: 'tcp', FromPort: '3389', ToPort: '3389', CidrIp: FnJoin( "", [ FnFindInMap('EnvironmentType', Ref('EnvironmentType'),'NetworkPrefix'),".", Ref('StackOctet'), ".0.0/", FnFindInMap('EnvironmentType', Ref('EnvironmentType'),'StackMask') ] ) },
      { IpProtocol: 'tcp', FromPort: '22', ToPort: '22', CidrIp: FnJoin( "", [ FnFindInMap('EnvironmentType', Ref('EnvironmentType'),'NetworkPrefix'),".", Ref('StackOctet'), ".0.0/", FnFindInMap('EnvironmentType', Ref('EnvironmentType'),'StackMask') ] ) },
      { IpProtocol: 'tcp', FromPort: '80', ToPort: '80', CidrIp: FnJoin( "", [ FnFindInMap('EnvironmentType', Ref('EnvironmentType'),'NetworkPrefix'),".", Ref('StackOctet'), ".0.0/", FnFindInMap('EnvironmentType', Ref('EnvironmentType'),'StackMask') ] ) },
      { IpProtocol: 'tcp', FromPort: '443', ToPort: '443', CidrIp: FnJoin( "", [ FnFindInMap('EnvironmentType', Ref('EnvironmentType'),'NetworkPrefix'),".", Ref('StackOctet'), ".0.0/", FnFindInMap('EnvironmentType', Ref('EnvironmentType'),'StackMask') ] ) },
      { IpProtocol: 'udp', FromPort: '123', ToPort: '123', CidrIp: FnJoin( "", [ FnFindInMap('EnvironmentType', Ref('EnvironmentType'),'NetworkPrefix'),".", Ref('StackOctet'), ".0.0/", FnFindInMap('EnvironmentType', Ref('EnvironmentType'),'StackMask') ] ) },
    ])
  }

  Resource("SecurityGroupInternalNat") {
    Type 'AWS::EC2::SecurityGroup'
    Property('VpcId', Ref('VPC'))
    Property('GroupDescription', 'Internal NAT SG')
    Property('SecurityGroupIngress', [
      { IpProtocol: 'tcp', FromPort: '1', ToPort: '65535', CidrIp: FnJoin( "", [ FnFindInMap('EnvironmentType', Ref('EnvironmentType'),'NetworkPrefix'),".", Ref('StackOctet'), ".0.0/", FnFindInMap('EnvironmentType', Ref('EnvironmentType'),'StackMask') ] ) }
    ])
  }

  Resource("Role") {
    Type 'AWS::IAM::Role'
    Property('AssumeRolePolicyDocument', {
      Statement: [
        Effect: 'Allow',
        Principal: { Service: [ 'ec2.amazonaws.com' ] },
        Action: [ 'sts:AssumeRole' ]
      ]
    })
    Property('Path','/')
    Property('Policies', [
      {
        PolicyName: 'read-only',
        PolicyDocument: {
          Statement: [
            {
              Effect: 'Allow',
              Action: [ 'ec2:Describe*', 's3:Get*', 's3:List*'],
              Resource: '*'
            }
          ]
        }
      },
      {
        PolicyName: 'describe-ec2-autoscaling',
        PolicyDocument: {
          Statement: [
            {
              Effect: 'Allow',
              Action: ['ec2:Describe*', 'autoscaling:Describe*' ],
              Resource: '*'
            }
          ]
        }
      },
      {
        PolicyName: 'associate-address',
        PolicyDocument: {
          Statement: [
            {
              Effect: 'Allow',
              Action: ['ec2:AssociateAddress'],
              Resource: '*'
            }
          ]
        }
      }
    ])
  }

  Resource("InstanceProfile") {
    Type 'AWS::IAM::InstanceProfile'
    Property('Path','/')
    Property('Roles',[ Ref('Role') ])
  }

  availability_zones.each do |az|
    Resource("RouteOutToInternet#{az}") {
      Type 'AWS::EC2::Route'
      Property('RouteTableId', Ref("RouteTablePrivate#{az}"))
      Property('DestinationCidrBlock', '0.0.0.0/0')
      Property('NatGatewayId',Ref("NatGateway#{az}"))
    }
  end

  route_tables = []
  availability_zones.each do |az|
    route_tables << Ref("RouteTablePrivate#{az}")
  end

  Resource("VPCEndpoint") {
    Type "AWS::EC2::VPCEndpoint"
    Property("PolicyDocument", {
      Version:"2012-10-17",
      Statement:[{
        Effect:"Allow",
        Principal: "*",
        Action:["s3:*"],
        Resource:["arn:aws:s3:::*"]
      }]
     })
     Property("RouteTableIds", route_tables)
     Property("ServiceName", FnJoin("", [ "com.amazonaws.", Ref("AWS::Region"), ".s3"]))
     Property("VpcId",  Ref('VPC'))
   }

  Resource("LaunchConfig") {
    Type 'AWS::AutoScaling::LaunchConfiguration'
    Property('ImageId', FnFindInMap('BastionAMI',Ref('AWS::Region'),'ami') )
    Property('AssociatePublicIpAddress',true)
    Property('IamInstanceProfile', Ref('InstanceProfile'))
    Property('KeyName', FnFindInMap('AccountId', Ref('AWS::AccountId'),'KeyName') )
    Property('SecurityGroups',[ Ref('SecurityGroupBackplane'),Ref('SecurityGroupInternalNat'),Ref('SecurityGroupOps'),Ref('SecurityGroupDev') ])
    Property('InstanceType', FnFindInMap('EnvironmentType', Ref('EnvironmentType'),'BastionInstanceType'))
    Property('UserData', FnBase64(FnJoin("",[
      "#!/bin/bash\n",
      "export NEW_HOSTNAME=", Ref('EnvironmentName') ,"-bastion-xx-`/opt/aws/bin/ec2-metadata --instance-id|/usr/bin/awk '{print $2}'`\n",
      "echo \"NEW_HOSTNAME=$NEW_HOSTNAME\" \n",
      "hostname $NEW_HOSTNAME\n",
      "sed -i \"s/^HOSTNAME=.*/HOSTNAME=$NEW_HOSTNAME/\" /etc/sysconfig/network\n",
      "aws --region ", Ref("AWS::Region"), " ec2 associate-address --allocation-id ", FnGetAtt('BastionIPAddress','AllocationId') ," --instance-id $(curl http://169.254.169.254/2014-11-05/meta-data/instance-id -s)\n"
    ])))
  }

  subnets = []
  availability_zones.each do |az|
    subnets << Ref("SubnetPublic#{az}")
  end

  AutoScalingGroup("AutoScaleGroup") {
    UpdatePolicy("AutoScalingRollingUpdate", {
      "MinInstancesInService" => "0",
      "MaxBatchSize"          => "1",
    })
    LaunchConfigurationName Ref("LaunchConfig")
    HealthCheckGracePeriod '500'
    MinSize 1
    MaxSize 1
    VPCZoneIdentifier subnets
    addTag("Name", FnJoin("",[Ref('EnvironmentName'), "-bastion-xx"]), true)
    addTag("Environment",Ref('EnvironmentName'), true)
    addTag("EnvironmentType", Ref('EnvironmentType'), true)
    addTag("Role", "bastion", true)
  }

  Resource("BastionRecord") {
    Type 'AWS::Route53::RecordSet'
    Property('HostedZoneId', Ref('HostedZone') )
    Property('Name', FnJoin('', [ 'bastion.', Ref('EnvironmentName'), '.', FnFindInMap('AccountId',Ref('AWS::AccountId'),'DnsDomain'), '.' ]))
    Property('Type','A')
    Property('TTL', '60')
    Property('ResourceRecords', [ Ref('BastionIPAddress') ])
  }

  Output("VPCId") {
    Value(Ref('VPC'))
  }

  availability_zones.each do |az|
    Output("RouteTablePrivate#{az}") {
      Value(Ref("RouteTablePrivate#{az}"))
    }
  end

  availability_zones.each do |az|
    Output("SubnetPublic#{az}") {
      Value(Ref("SubnetPublic#{az}"))
    }
  end

  Output("SecurityGroupBackplane") {
    Value(Ref('SecurityGroupBackplane'))
  }

  Output("SecurityGroupOps") {
    Value(Ref('SecurityGroupOps'))
  }

  Output("SecurityGroupDev") {
    Value(Ref('SecurityGroupDev'))
  }

}
