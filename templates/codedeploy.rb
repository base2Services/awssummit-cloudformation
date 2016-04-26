require_relative '../ext/codedeploy'
if !((defined?codedeploy).nil?)
  create_stack_codedeploy(codedeploy)
end
