# IPVSS: M-NVR + CMS + RPF, integrated

    bash start.sh              # starts everything (first run also sets up databases)
    bash start.sh status | logs [mnvr|cms|rpf|bridge] | stop
    bash start.sh --demo-data  # optional: demo zones/posts/logins in a fresh CMS

* `mnvr/` - unchanged M-NVR (train)  * `RPF_CMS/` - unchanged CMS + RPF  * `bridge/` - NEW agent M-NVR -> CMS
* The bridge needs no train name/number: it reads them from the M-NVR (`device_name`, `train_number` in its
  system_config) and registers the unit and its cameras in CMS by itself. Details: `docs/INTEGRATION.md`.
