from diagrams import Diagram
from diagrams.aws.compute import Lambda
from diagrams.aws.network import APIGateway
from diagrams.aws.storage import S3
from diagrams.aws.security import WAF
from diagrams.aws.general import User
from diagrams.aws.management import Cloudtrail, Config
from diagrams.aws.security import Guardduty
from diagrams.aws.integration import SNS

with Diagram("HIPAA Cloud Architecture", show=True, filename="../images/hipaa-cloud-architecture-", outformat="png"):
    user = User("User")
    api = APIGateway("API Gateway")
    lamb = Lambda("Lambda")
    s3 = S3("Encrypted S3")
    trail = Cloudtrail("CloudTrail")
    config = Config("AWS Config")
    guard = Guardduty("GuardDuty")
    sns = SNS("Alerts/Findings")

    user >> api >> lamb >> s3
    s3 >> [trail, config, guard]
    [trail, config, guard] >> sns
