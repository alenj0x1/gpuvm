# Lab 050 desk research (2026-11-18, primary sources; what stays unverified is marked)

1. **Host registration** (`GuestCommunicationServices\{guid}`): only `ElementName` is documented; registering the GUID
   is what lets VMs talk to the service. No security descriptor value is documented.
   https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/make-integration-service
2. **HCS** `HvSocketSystemConfig` / `HvSocketServiceConfig` (Bind/ConnectSecurityDescriptor, AllowWildcardBinds,
   ServiceTable): SDDL checks on **host** processes binding/connecting for a compute system; nothing limits which
   guest process connects. Only for HCS compute systems (containers, UVMs, AppSandbox); nothing documented for VMMS
   VMs. https://learn.microsoft.com/en-us/virtualization/api/hcs/schemareference ,
   https://github.com/microsoft/hcsshim/blob/main/internal/hcs/schema2/hv_socket_system_config.go
3. **Guest side**: no documented guest registry or SDDL in the guest's hvsocket.sys; which guest users may open
   `AF_HYPERV` is undocumented -> measured in this lab.
4. **Peer VmId**: in the Linux guest driver, the connect message carries only the endpoint and service GUIDs, so the
   host's VMBus must take the VmId from the partition the message came from (not forgeable by the guest). Inferred
   from https://github.com/torvalds/linux/blob/master/drivers/hv/channel.c (`vmbus_send_tl_connect_request`); not
   stated by Microsoft. It identifies the VM, never the process or user inside it.
5. **Other projects**: AppSandbox (MIT, HCS-based) sets Everyone descriptors, `AllowWildcardBinds`, guest agent
   listens on HV_GUID_WILDCARD, host connects to the VM's RuntimeId; **no authentication**. Podman on Hyper-V
   (VMMS): host listens, waits for a ready message, no auth. PowerShell Direct authenticates in-band with
   user+password (Microsoft does not trust the channel alone).
6. **KVP**: Microsoft makes no confidentiality claim ("both the guest and the host can see it").
   https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/integration-services ; lab 042 found
   `...\Virtual Machine\External` readable by Authenticated Users -> a secret there is not private (measured here).
7. **Copy-VMFile** (Guest Service Interface, off by default) copies a host file to a guest path; owner/ACL of the
   written file undocumented -> measured here.
   https://learn.microsoft.com/en-us/powershell/module/hyper-v/copy-vmfile
