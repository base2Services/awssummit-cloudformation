def nest_stack_codedeploy (codedeploy,template_url)
  depends = []
  params = { EnvironmentName: Ref('EnvironmentName') }
  if codedeploy.key?('applications')
    codedeploy['applications'].each do |applications|
      if applications.include?('deployment_groups')
        applications['deployment_groups'].each do |deployment_groups|
          if deployment_groups['type']=='asg'
            asg_output_stack=deployment_groups['asg_output_stack']
            asg_output_param=deployment_groups['asg_output_param']
            params["#{asg_output_stack}#{asg_output_param}"] = FnGetAtt(asg_output_stack, "Outputs.#{asg_output_param}")
            depends << asg_output_stack
          end
        end; nil
      end
    end; nil
  end
  Resource("CodeDeployStack") {
    DependsOn(depends)
    Type 'AWS::CloudFormation::Stack'
    Property('TemplateURL', template_url )
    Property('TimeoutInMinutes', 5)
    Property('Parameters', params)
  }
end

def create_stack_codedeploy (codedeploy)
  if !((defined?codedeploy).nil?)
    CloudFormation do
      Parameter("EnvironmentName"){ Type 'String' }
      Resource("CodeDeployRole") {
        Type 'AWS::IAM::Role'
        Property('AssumeRolePolicyDocument', {
          'Statement' => [
            'Effect' => 'Allow',
            'Principal' => {
              'Service' => [
                'codedeploy.us-east-1.amazonaws.com',
                'codedeploy.us-west-2.amazonaws.com',
                'codedeploy.eu-west-1.amazonaws.com',
                'codedeploy.ap-southeast-2.amazonaws.com'
              ]
            },
            'Action' => [ 'sts:AssumeRole' ]
          ]
        })
        Property('Path','/')
        Property('Policies', [
          'PolicyName' => 'CodeDeployRole',
          'PolicyDocument' => {
            'Statement' => [
              {
                'Effect' => 'Allow',
                'Action' => [
                  'autoscaling:CompleteLifecycleAction',
                  'autoscaling:DeleteLifecycleHook',
                  'autoscaling:DescribeAutoScalingGroups',
                  'autoscaling:DescribeLifecycleHooks',
                  'autoscaling:PutLifecycleHook',
                  'autoscaling:RecordLifecycleActionHeartbeat',
                  'ec2:DescribeInstances',
                  'ec2:DescribeInstanceStatus',
                  'tag:GetTags',
                  'tag:GetResources'
                ],
                'Resource' => '*'
              }
            ]
          }
        ])
      }
      if codedeploy.key?('applications')
        codedeploy['applications'].each do |applications|
          codedeploy_application_name=applications['name']
          Resource("#{codedeploy_application_name}CodeDeployApplication") {
            Type 'AWS::CodeDeploy::Application'
            Property('ApplicationName', FnJoin('', [ Ref('EnvironmentName'), "-#{codedeploy_application_name}" ]))
          }
          if applications.include?('deployment_groups')
            applications['deployment_groups'].each do |deployment_groups|
              codedeploy_deployment_group_name=deployment_groups['name']
              codedeploy_deployment_config_name=deployment_groups['deployment_config_name']
              if deployment_groups['type']=='asg'
                codedeploy_deployment_type='asg'
                asg_output_stack=deployment_groups['asg_output_stack']
                asg_output_param=deployment_groups['asg_output_param']
                Parameter("#{asg_output_stack}#{asg_output_param}"){ Type 'String' }
                Resource("#{codedeploy_deployment_group_name}DeploymentGroup") {
                  Type 'AWS::CodeDeploy::DeploymentGroup'
                  Property('DeploymentGroupName', FnJoin('', [ Ref('EnvironmentName'), "-#{codedeploy_deployment_group_name}" ]))
                  Property('ApplicationName', Ref("#{codedeploy_application_name}CodeDeployApplication"))
                  Property('AutoScalingGroups', [Ref("#{asg_output_stack}#{asg_output_param}")])
                  Property('DeploymentConfigName', "#{codedeploy_deployment_config_name}")
                  Property('ServiceRoleArn', FnGetAtt('CodeDeployRole','Arn'))
                }
              end
              if deployment_groups['type']=='tag'
                codedeploy_deployment_type='tag'
                codedeploy_tag_key=deployment_groups['tag_key']
                codedeploy_tag_value=deployment_groups['tag_value']
                Resource("#{codedeploy_deployment_group_name}DeploymentGroup") {
                  Type 'AWS::CodeDeploy::DeploymentGroup'
                  Property('DeploymentGroupName', FnJoin('', [ Ref('EnvironmentName'), "-#{codedeploy_deployment_group_name}" ]))
                  Property('ApplicationName', Ref("#{codedeploy_application_name}CodeDeployApplication"))
                  Property('DeploymentConfigName', "#{codedeploy_deployment_config_name}")
                  if deployment_groups['tag_value_EnvironmentName_prefix']==true
                      Property('Ec2TagFilters', [{
                        Key: "#{codedeploy_tag_key}",
                        Value: FnJoin('', [ Ref('EnvironmentName'), "-#{codedeploy_tag_value}" ]),
                        Type: 'KEY_AND_VALUE',
                      }])
                  else
                    Property('Ec2TagFilters', [{
                      Key: "#{codedeploy_tag_key}",
                      Value: "#{codedeploy_tag_value}",
                      Type: 'KEY_AND_VALUE',
                    }])
                  end
                  Property('ServiceRoleArn', FnGetAtt('CodeDeployRole','Arn'))
                }
              end
            end; nil
          end
        end; nil
      end
    end
  end
end
