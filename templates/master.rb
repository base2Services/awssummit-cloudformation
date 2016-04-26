require 'cfndsl'
require_relative '../ext/codedeploy'

CloudFormation do

  # Template metadata
  AWSTemplateFormatVersion '2010-09-09'
  Description "#{application_name} - Master v#{cf_version}"

  Parameter("EnvironmentType"){
    Type 'String'
    AllowedValues ['production','dev']
    Default 'dev'
  }

  Parameter("EnvironmentName"){
    Type 'String'
  }

  Parameter("StackOctet") {
    Type 'String'
    Default '99'
  }

  availability_zones.each do |az|
    Parameter("Nat#{az}EIPAllocationId") {
      Description 'Enter the eip allocation id or use dynamic to generate EIP as part of the stack'
      Type 'String'
      Default 'dynamic'
    }
  end

  vpc_params = {
    EnvironmentType: Ref('EnvironmentType'),
    EnvironmentName: Ref('EnvironmentName'),
    StackOctet: Ref('StackOctet')
  }
  availability_zones.each do |az|
    vpc_params.merge!("Nat#{az}EIPAllocationId" => Ref("Nat#{az}EIPAllocationId"))
  end
  Resource("VPCStack") {
    Type 'AWS::CloudFormation::Stack'
    Property('TemplateURL', "https://#{source_bucket}.s3.amazonaws.com/cloudformation/#{cf_version}/vpc.json" )
    Property('TimeoutInMinutes', 5)
    Property('Parameters', vpc_params )
  }

  shared_params = {
    EnvironmentType: Ref('EnvironmentType'),
    EnvironmentName: Ref('EnvironmentName'),
    VPC: FnGetAtt('VPCStack', 'Outputs.VPCId'),
    StackOctet: Ref('StackOctet'),
    SecurityGroupBackplane: FnGetAtt('VPCStack', 'Outputs.SecurityGroupBackplane'),
    SecurityGroupOps: FnGetAtt('VPCStack', 'Outputs.SecurityGroupOps'),
    SecurityGroupDev: FnGetAtt('VPCStack', 'Outputs.SecurityGroupDev')
  }
  availability_zones.each do |az|
    shared_params.merge!("SubnetPublic#{az}" => FnGetAtt('VPCStack', "Outputs.SubnetPublic#{az}"))
    shared_params.merge!("RouteTablePrivate#{az}" => FnGetAtt('VPCStack', "Outputs.RouteTablePrivate#{az}"))
  end
  Resource("AppStack") {
    Type 'AWS::CloudFormation::Stack'
    Property('TemplateURL', "https://#{source_bucket}.s3.amazonaws.com/cloudformation/#{cf_version}/app.json" )
    Property('TimeoutInMinutes', 5)
    Property('Parameters', shared_params )
  }

  if !((defined?codedeploy).nil?)
    nest_stack_codedeploy(codedeploy,"https://#{source_bucket}.s3.amazonaws.com/cloudformation/#{cf_version}/codedeploy.json")
  end
end
