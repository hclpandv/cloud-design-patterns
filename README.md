# randon notes

```kql
NTANetAnalytics 
| where SubType == "FlowLog" and FlowStartTime > ago(30m) and FlowType == "ExternalPublic" 
| where FlowStatus contains "Allowed" 
| project TimeProcessed, FlowType, DestIp, DestPort, L7Protocol, FlowDirection, Country, SrcPublicIps
```

```kql
NSPAccessLogs 
| where OperationName == "GetBlob" and TimeGenerated > ago(30m) 
| project TimeGenerated, Location, ResultAction, ResultDirection, ResultDescription, SourceIpAddress
```

# Public GH page serves below service:


1. Azure blueprint viewer:  https://hclpandv.github.io/cloud-design-patterns/
2. Flowchart viewer: https://hclpandv.github.io/cloud-design-patterns/flowchart