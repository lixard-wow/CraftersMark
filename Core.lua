---@diagnostic disable: undefined-global, undefined-field, redundant-parameter, missing-parameter, need-check-nil
if InCombatLockdown() then return end

CraftersMark = LibStub("AceAddon-3.0"):NewAddon("CraftersMark", "AceComm-3.0", "AceHook-3.0")

local Serializer = LibStub("LibSerialize")
local Compressor = LibStub("LibDeflate")
local COMM_PREFIX = "CM_CrafterQuery"
local CHANNEL_NAME = "CrafterNetwork"

local addon = CraftersMark
addon.settings = aura_env and aura_env.config or {delay = 30}
addon.unlockAllEnabled = false

function addon:OnInitialize()
    if self.ready then return end
    self.ready = true
    self:RegisterComm(COMM_PREFIX)
    self.resultsProvider = CreateDataProvider()

    C_AddOns.LoadAddOn("Blizzard_ProfessionsCustomerOrders")
    C_AddOns.LoadAddOn("Blizzard_Professions")
    C_AddOns.LoadAddOn("Blizzard_AuctionHouseUI")

    C_Timer.After(tonumber(self.settings.delay) or 30, function()
        self:SetupChannel()
    end)

    self.orderForm = ProfessionsCustomerOrdersFrame.Form

    self:SecureHookScript(self.orderForm, "OnShow")
    self:SecureHookScript(self.orderForm, "OnHide")
    self:SecureHookScript(self.orderForm.OrderRecipientTarget, "OnEditFocusLost", "UpdateTargetCrafter")
    self:SecureHookScript(self.orderForm.OrderRecipientTarget, "OnShow", "UpdateTargetCrafter")
    self:SecureHookScript(self.orderForm.OrderRecipientTarget, "OnHide", "RefreshQualityDisplay")
    self:SecureHookScript(self.orderForm.ReagentContainer.Reagents, "OnShow", "SetupReagentToggle")
    self:SecureHookScript(self.orderForm.ReagentContainer.Reagents, "OnHide", "SetupReagentToggle")

    self:SecureHookScript(ProfessionsFrame, "OnShow", "CreateOrdersAccess")
    self:SecureHookScript(ProfessionsFrame, "OnHide", "OnProfessionsFrameHide")
    self:SecureHookScript(AuctionHouseFrame.TitleContainer, "OnShow", "CreateOrdersAccess")

    local cf = ProfessionsFrame.CraftingPage.SchematicForm
    local of = ProfessionsFrame.OrdersPage.OrderView.OrderDetails.SchematicForm
    self:SecureHookScript(cf.Reagents, "OnShow", "SetupReagentToggle")
    self:SecureHookScript(cf.Reagents, "OnHide", "SetupReagentToggle")
    self:SecureHookScript(cf.FinishingReagents, "OnShow", "SetupReagentToggle")
    self:SecureHookScript(cf.FinishingReagents, "OnHide", "SetupReagentToggle")
    self:SecureHookScript(of.Reagents, "OnShow", "SetupReagentToggle")
    self:SecureHookScript(of.Reagents, "OnHide", "SetupReagentToggle")
    self:SecureHookScript(of.FinishingReagents, "OnShow", "SetupReagentToggle")
    self:SecureHookScript(of.FinishingReagents, "OnHide", "SetupReagentToggle")
    self:SecureHookScript(cf.Details, "OnUpdate", "ShowSkillDetails")
    self:SecureHookScript(of.Details, "OnUpdate", "ShowSkillDetails")

    SLASH_CRAFTERSMARK1 = "/cm"
    SlashCmdList["CRAFTERSMARK"] = function(msg)
        if msg == "debug" then addon:DebugFlyout() end
    end

    print("|cff00ff00CraftersMark loaded|r")
end

function addon:SetupChannel()
    self.channelIndex = GetChannelName(CHANNEL_NAME)
    if self.channelIndex == 0 then
        JoinPermanentChannel(CHANNEL_NAME, nil, nil, false)
        self.channelIndex = GetChannelName(CHANNEL_NAME)
    end
end

function addon:OnShow()
    self.resultsProvider = CreateDataProvider()
    self.chosenCrafter = nil
    self.lastAllocation = nil
    self.allocationTimer = nil

    self:BuildSearchButton()
    self:SetupReagentToggle(self.orderForm.ReagentContainer)
    self:RefreshQualityDisplay()

    EventRegistry:RegisterCallback("Professions.AllocationUpdated", function(...) self:OnAllocationChange(...) end, self)
end

function addon:OnHide()
    EventRegistry:UnregisterCallback("Professions.AllocationUpdated", self)
end

-- Called when ProfessionsFrame hides (walking away from bench, closing window, etc.).
-- Ensures unlock hooks and watchers are always torn down when leaving the crafting UI,
-- regardless of whether the checkbox's OnHide fired first.
function addon:OnProfessionsFrameHide()
    self:UnhookAll()
    self:SetFlyoutWatcher(false)
    self._reagentCache = nil
end

function addon:UnhookAll()
    addon.unlockAllEnabled = false
    if self:IsHooked(ItemUtil, "GetCraftingReagentCount") then self:Unhook(ItemUtil, "GetCraftingReagentCount") end
    if ProfessionsUtil and self:IsHooked(ProfessionsUtil, "GetReagentQuantityInPossession") then self:Unhook(ProfessionsUtil, "GetReagentQuantityInPossession") end
    if self:IsHooked(C_Item, "GetItemCount") then self:Unhook(C_Item, "GetItemCount") end
    if self:IsHooked(_G, "GetItemCount") then self:Unhook(_G, "GetItemCount") end
    if C_TradeSkillUI and self:IsHooked(C_TradeSkillUI, "GetHideUnownedFlags") then self:Unhook(C_TradeSkillUI, "GetHideUnownedFlags") end
end

function addon:CreateOrdersAccess(parent)
    local frameName = 'CMOrderBtn' .. (parent:GetName() or parent:GetParent():GetName() or "Main")
    local button = _G[frameName] or CreateFrame("Button", frameName, parent, "UIPanelButtonTemplate")
    button:SetFrameLevel(600)
    button:ClearAllPoints()
    button:SetSize(24, 24)
    button:SetText("O")

    if AuctionHouseFrame and parent == AuctionHouseFrame.TitleContainer then
        button:SetPoint("TOPLEFT", 10, 1)
    else
        button:SetPoint("TOPLEFT", 90, 1)
    end

    if not button.ordersFrame then
        local frame = ProfessionsCustomerOrdersFrame
        frame:SetMovable(true)
        frame:SetClampedToScreen(true)
        frame.ignoreFramePositionManager = true
        frame:RegisterForDrag("LeftButton")
        frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
        frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
        button.ordersFrame = frame
    end

    button:SetScript("OnClick", function(self) self.ordersFrame:Show() end)
end

function addon:SetupReagentToggle(container)
    if _G.CMResultsList then _G.CMResultsList:Hide() end
    if not container then return end

    local toggle = container.ReagentUnlocker or self:BuildReagentCheckbox(container)
    if not toggle then return end

    toggle:ClearAllPoints()
    toggle:SetChecked(self.unlockAllEnabled)

    if container.Label and container.Label:IsVisible() then
        toggle:SetPoint("LEFT", container.Label, "LEFT", container.Label:GetWrappedWidth(), 0)
        toggle:Show()
    else
        toggle:Hide()
    end

end

function addon:OnAllocationChange()
    if not self.orderForm or not self.orderForm.transaction then return end
    local currentAlloc = self.orderForm.transaction:CreateCraftingReagentInfoTbl()
    if not self.lastAllocation then self.lastAllocation = currentAlloc end

    if not self:TableEquals(currentAlloc, self.lastAllocation) then
        self.lastAllocation = currentAlloc
        if self.allocationTimer then self.allocationTimer:Cancel() end
        self.allocationTimer = C_Timer.NewTimer(0.1, function()
            self:UpdateTargetCrafter()
        end)
    end
end

function addon:SendMessage(payload, recipient)
    local encoded = Compressor:EncodeForWoWAddonChannel(
        Compressor:CompressDeflate(Serializer:Serialize(payload)))

    if recipient and string.len(recipient) > 2 then
        self:SendCommMessage(COMM_PREFIX, encoded, "WHISPER", recipient)
    elseif self.channelIndex and payload.query and payload.query.recipeID then
        self:SendCommMessage(COMM_PREFIX, encoded, "CHANNEL", self.channelIndex)
    end
end

function addon:OnCommReceived(prefix, message, channel, sender)
    local decoded = Compressor:DecodeForWoWAddonChannel(message)
    if not decoded then return end
    local decompressed = Compressor:DecompressDeflate(decoded)
    if not decompressed then return end
    local ok, payload = Serializer:Deserialize(decompressed)
    if not ok then return end

    if payload.reply and sender and string.len(sender) > 2 then
        self:StoreResult({crafter = sender, info = payload.reply})
        self:RefreshQualityDisplay()
    end

    if payload.query and payload.query.recipeID then
        local known = C_TradeSkillUI.IsRecipeProfessionLearned(payload.query.recipeID)
        local recipe = C_TradeSkillUI.GetRecipeInfo(payload.query.recipeID)

        if known then
            local crafting
            if payload.query.isRecraft and C_TradeSkillUI.GetCraftingOperationInfoForRecraft then
                crafting = C_TradeSkillUI.GetCraftingOperationInfoForRecraft(
                    payload.query.recipeID, payload.query.reagents or {}, nil)
            end
            if not crafting or crafting.baseSkill == 0 then
                crafting = C_TradeSkillUI.GetCraftingOperationInfo(
                    payload.query.recipeID, payload.query.reagents or {})
            end

            if not crafting or crafting.baseSkill == 0 then return end
            crafting.learned = (not recipe and "notloaded") or (not recipe.learned and "notlearned")
            self:SendMessage({reply = crafting}, sender)
        end
    end
end

function addon:StoreResult(entry)
    if not self.resultsProvider then self.resultsProvider = CreateDataProvider() end
    self.resultsProvider:RemoveByPredicate(function(el)
        return el.crafter and entry.crafter and el.crafter == entry.crafter
    end)
    self.resultsProvider:Insert(entry)
end

function addon:UpdateTargetCrafter()
    local target = self.orderForm.OrderRecipientTarget:GetText()
    if target and string.len(target) > 3 then
        self:RequestCrafterInfo(target)
    end
end

function addon:RequestCrafterInfo(target)
    local trans = self.orderForm.transaction
    if not trans or not trans.recipeID then return end

    local isRecraft = false
    pcall(function() isRecraft = trans:GetRecraftItemGUID() ~= nil end)

    self:SendMessage({
        query = {
            recipeID = trans.recipeID,
            reagents = trans:CreateCraftingReagentInfoTbl() or {},
            isRecraft = isRecraft,
        }
    }, target)
end

function addon:OnSearchClick(button, ...)
    if self.channelIndex == 0 then
        self:SetupChannel()
    else
        self.resultsProvider:Flush()
        self:RequestCrafterInfo()
        self:ShowResultsList(button)
    end
end

function addon:ChooseCrafter(entry)
    self.chosenCrafter = entry
    if self.orderForm and self.orderForm.OrderRecipientTarget then
        self.orderForm.OrderRecipientTarget:SetText(entry.crafter)
        self:RefreshQualityDisplay()
    end
end

function addon:BuildSearchButton()
    local form = self.orderForm
    local button = _G.CMSearchButton or CreateFrame("Button", "CMSearchButton", form.OrderRecipientTarget, "UIPanelButtonTemplate")

    button:SetSize(80, 22)
    button:SetTextToFit("Find")
    button:SetPoint("TOPRIGHT", form.OrderRecipientTarget, "TOPLEFT", -31, 0)
    button:SetScript("OnClick", function(btn, ...) addon:OnSearchClick(btn, ...) end)
    button:SetScript("OnUpdate", function(btn)
        addon.channelIndex = GetChannelName(CHANNEL_NAME)
        btn:SetTextToFit(addon.channelIndex == 0 and "Join" or "Find")
    end)
    self.searchButton = button
end

function addon:RefreshQualityDisplay()
    local form = ProfessionsCustomerOrdersFrame.Form
    if not form:IsVisible() or not form.transaction then return end

    local recipeID = form.transaction.recipeID
    local target = form.OrderRecipientTarget
    local name = target and target:GetText()

    if target and target:IsVisible() and name and recipeID and string.len(name) > 2 then
        local function matches(el)
            return el and el.crafter and el.info and name and recipeID
                and el.crafter == name and el.info.recipeID == recipeID
        end

        local _, result = self.resultsProvider:FindByPredicate(matches)

        if matches(result) then
            form:SetMinimumQualityIndex(result.info.craftingQuality)
            form:UpdateMinimumQuality()
            form.MinimumQuality.Dropdown:Hide()

            local label = form.MinimumQuality
            label.Text:ClearAllPoints()
            label.Text:SetPoint("RIGHT", label.Dropdown, "LEFT", -25, 0)

            local display = _G.CMQualityDisplay or CreateFrame("Frame", "CMQualityDisplay", label)
            display:ClearAllPoints()
            display:SetPoint("LEFT", label.Text, "RIGHT", 0, 0)
            display:SetSize(100, 40)
            display:Show()

            local qualityText = _G.CMQualityText or display:CreateFontString("CMQualityText", "ARTWORK", "GameFontNormal")
            qualityText:ClearAllPoints()
            qualityText:SetPoint("TOPLEFT", display, "TOPLEFT", 0, -8)
            qualityText:SetText(self:FormatCrafterInfo(result, true))
            qualityText:Show()

            local skillText = _G.CMSkillText or display:CreateFontString("CMSkillText", "ARTWORK", "GameFontNormal")
            skillText:SetText(format("Skill: %d/%d",
                result.info.baseSkill + result.info.bonusSkill,
                result.info.baseDifficulty + result.info.bonusDifficulty))
            skillText:SetTextColor(GRAY_FONT_COLOR.r, GRAY_FONT_COLOR.g, GRAY_FONT_COLOR.b)
            skillText:ClearAllPoints()
            skillText:SetPoint("TOPLEFT", display, "TOPLEFT", 2, -32)
            skillText:SetScale(0.7)
            skillText:Show()
            return
        end
    end

    form:UpdateMinimumQualityAnchor()
    form:UpdateMinimumQuality()
    form.MinimumQuality.Dropdown:Show()
    if _G.CMQualityDisplay then _G.CMQualityDisplay:Hide() end
end

function addon:ShowResultsList(anchor)
    local list = _G.CMResultsList or CreateFrame("Frame", "CMResultsList", anchor:GetParent(), "TooltipBackdropTemplate")
    local scrollBox = _G.CMResultsScrollBox or CreateFrame("Frame", "$parentScrollBox", list, "WowScrollBoxList")
    local scrollBar = _G.CMResultsScrollBar or CreateFrame("EventFrame", "$parentScrollBar", list, "MinimalScrollBar")

    list:SetFrameStrata("TOOLTIP")
    list:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 5, 0)
    list:SetSize(250, 100)
    list:RegisterEvent("GLOBAL_MOUSE_DOWN")
    list:SetScript("OnEvent", function(self, event, ...)
        if event == "GLOBAL_MOUSE_DOWN" then
            local buttonName = ...
            local isRight = buttonName == "RightButton"
            local mouseFocus = GetMouseFocus()
            if not isRight and DoesAncestryInclude(self.owner, mouseFocus) then return end
            if isRight or (not DoesAncestryInclude(self, mouseFocus) and mouseFocus ~= self) then
                self:Hide()
            end
        end
    end)

    scrollBox:SetPoint("TOPLEFT", 2, -4)
    scrollBox:SetPoint("BOTTOMRIGHT", 2, 4)
    scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 0, 0)
    scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 0, 0)

    local view = CreateScrollBoxListLinearView(4, 4, 4, 4)
    view:SetElementExtent(20)
    view:SetDataProvider(self.resultsProvider)

    view:SetElementInitializer("Button", function(button, elementData)
        if not button.setup then
            button.setup = true
            button.label = button:CreateFontString(nil, "OVERLAY", "GameTooltipText")
            button.label:SetPoint("LEFT", 4, 0)
            button.label:SetFontObject("GameFontNormal")
            button.label:SetTextColor(1, 1, 1)
            button:SetHighlightTexture("auctionhouse-ui-row-highlight")
            button:GetHighlightTexture():SetBlendMode("ADD")
            button:GetHighlightTexture():SetAllPoints()
            button:SetScript("OnClick", function(btn) list:SelectEntry(btn.elementData) end)
        end
        button.label:SetText(addon:FormatCrafterInfo(elementData))
        button.elementData = elementData
    end)
    ScrollUtil.InitScrollBoxWithScrollBar(scrollBox, scrollBar, view)

    list.addon = self
    list.owner = anchor
    function list:SelectEntry(...)
        self.addon:ChooseCrafter(...)
        self:Hide()
    end

    list:Show()
end

-- Patch a single flyout frame's per-instance behavior object.
-- Mixins are copied by value in WoW, so hooking the mixin table is not
-- enough — each flyout instance needs its own behavior patched directly.
function addon:PatchFlyoutInstance(flyout)
    if not flyout then return end

    if not flyout._cmShowHooked then
        flyout._cmShowHooked = true
        flyout:HookScript("OnShow", function(f) addon:PatchFlyoutInstance(f) end)
    end

    local behavior = flyout.behavior
    if not behavior or behavior._cmPatched then return end
    behavior._cmPatched = true

    local origEnabled = behavior.IsElementEnabled
    behavior.IsElementEnabled = function(b, ed, c)
        if addon.unlockAllEnabled then return true end
        if origEnabled then return origEnabled(b, ed, c) end
        return false
    end

    local origFlags = behavior.GetUnownedFlags
    if type(origFlags) == "function" then
        behavior.GetUnownedFlags = function(b, ...)
            if addon.unlockAllEnabled then
                return {alwaysShowUnavailable = true, cannotModifyHideUnavailable = false}
            end
            return origFlags(b, ...)
        end
    end

    -- Hook the ScrollBox's own OnUpdate so buttons are re-enabled after every render.
    -- The Disable hook alone isn't enough because pool frames cycle in and out.
    if flyout.ScrollBox and not flyout.ScrollBox._cmUpdateHooked then
        flyout.ScrollBox._cmUpdateHooked = true
        flyout.ScrollBox:HookScript("OnUpdate", function(sb, dt)
            sb._cmElapsed = (sb._cmElapsed or 0) + dt
            if sb._cmElapsed < 0.05 then return end
            sb._cmElapsed = 0
            if addon.unlockAllEnabled then
                pcall(function() addon:EnableFlyoutButtons(flyout) end)
            end
        end)
    end

    pcall(function() addon:EnableFlyoutButtons(flyout) end)
end

-- Scan direct children of the schematic forms for open flyout frames and patch them.
function addon:PatchVisibleFlyouts()
    local function scanChildren(parent)
        if not parent then return end
        local ok, n = pcall(function() return parent:GetNumChildren() end)
        if not ok or not n then return end
        for i = 1, n do
            local ok2, child = pcall(function() return select(i, parent:GetChildren()) end)
            if ok2 and child then
                local ok3, hasBehavior = pcall(function() return child.behavior ~= nil end)
                if ok3 and hasBehavior then
                    self:PatchFlyoutInstance(child)
                end
            end
        end
    end

    local pf = ProfessionsFrame
    local cf = pf and pf.CraftingPage and pf.CraftingPage.SchematicForm
    local of = pf and pf.OrdersPage and pf.OrdersPage.OrderView
        and pf.OrdersPage.OrderView.OrderDetails
        and pf.OrdersPage.OrderView.OrderDetails.SchematicForm
    scanChildren(cf)
    scanChildren(of)
end

-- Directly enable every button rendered in the flyout's ScrollTarget.
-- Needed because the button enabled state is baked into element data at
-- flyout build time — patching IsElementEnabled alone doesn't re-enable them.
function addon:EnableFlyoutButtons(flyout)
    if not flyout or not flyout.ScrollBox then return end
    local target = flyout.ScrollBox.ScrollTarget
    if not target then return end
    pcall(function()
        for i = 1, target:GetNumChildren() do
            local child = select(i, target:GetChildren())
            if child then
                -- Hook Disable so re-renders can't gray the button back out
                if not child._cmFlyoutHooked and child.Disable then
                    child._cmFlyoutHooked = true
                    hooksecurefunc(child, "Disable", function(s)
                        if addon.unlockAllEnabled then
                            s:Enable()
                            s.enabled = true  -- keep Lua field in sync with frame state
                            pcall(function()
                                local ed = s.GetElementData and s:GetElementData()
                                if ed and ed.reagent then
                                    if ed.reagent.currencyID then
                                        -- Crests are currencies — hide the count entirely
                                        s.count = 0
                                        if s.Count then s.Count:Hide() end
                                    elseif ed.reagent.itemID then
                                        local recipeID = addon:GetActiveRecipeID()
                                        if recipeID then
                                            local itemMap = addon:GetReagentRequirementMaps(recipeID)
                                            local qty = itemMap[ed.reagent.itemID]
                                            if qty then s.count = qty end
                                        end
                                    end
                                end
                            end)
                            if s.Icon then s.Icon:SetDesaturated(false) end
                            if s.SlotBackground then s.SlotBackground:SetDesaturated(false) end
                        end
                    end)
                end
                if child.Enable then child:Enable() end
                -- btn.enabled is the Lua field the OnClick handler checks before processing
                -- a selection. It's set by the flyout initializer based on IsElementEnabled,
                -- but the flyout opens before our behavior patch is applied, so it stays false.
                -- Setting it directly here is the only reliable way to ungate the click handler.
                child.enabled = true
                -- btn.count is set by the flyout initializer via a C-level API that bypasses
                -- our Lua hooks. For item reagents set it to the required quantity; for
                -- currency reagents (crests) hide the count frame entirely.
                pcall(function()
                    local ed = child.GetElementData and child:GetElementData()
                    if ed and ed.reagent then
                        if ed.reagent.currencyID then
                            child.count = 0
                            if child.Count then child.Count:Hide() end
                        elseif ed.reagent.itemID then
                            local recipeID = addon:GetActiveRecipeID()
                            if recipeID then
                                local itemMap = addon:GetReagentRequirementMaps(recipeID)
                                local qty = itemMap[ed.reagent.itemID]
                                if qty then child.count = qty end
                            end
                        end
                    end
                end)
                if child.Icon then child.Icon:SetDesaturated(false) end
                if child.SlotBackground then child.SlotBackground:SetDesaturated(false) end
            end
        end
    end)
end

-- Lightweight watcher: patches flyouts as they open while unlock is active.
-- Runs every 0.1s but only scans direct SchematicForm children so it's cheap.
function addon:SetFlyoutWatcher(enabled)
    if not self._flyoutWatcher then
        self._flyoutWatcher = CreateFrame("Frame")
        self._flyoutWatcher.elapsed = 0
        self._flyoutWatcher:SetScript("OnUpdate", function(f, dt)
            f.elapsed = f.elapsed + dt
            if f.elapsed < 0.1 then return end
            f.elapsed = 0
            addon:PatchVisibleFlyouts()
            -- Re-enable buttons on every tick in case the scroll view re-grays them
            local pf = ProfessionsFrame
            local cf = pf and pf.CraftingPage and pf.CraftingPage.SchematicForm
            local of = pf and pf.OrdersPage and pf.OrdersPage.OrderView
                and pf.OrdersPage.OrderView.OrderDetails
                and pf.OrdersPage.OrderView.OrderDetails.SchematicForm
            local function enableInForm(form)
                if not form then return end
                pcall(function()
                    for i = 1, form:GetNumChildren() do
                        local child = select(i, form:GetChildren())
                        local ok, hasBeh = pcall(function() return child.behavior ~= nil end)
                        if ok and hasBeh then addon:EnableFlyoutButtons(child) end
                    end
                end)
            end
            enableInForm(cf)
            enableInForm(of)
        end)
    end
    if enabled then
        self._flyoutWatcher:Show()
    else
        self._flyoutWatcher:Hide()
    end
end

-- Dump flyout state for debugging. Run: /cm debug
function addon:DebugFlyout()
    print("|cff00ff00CraftersMark Debug|r")
    print("unlockAllEnabled:", self.unlockAllEnabled)

    -- Check active recipe + schematic cache
    local activeRecipeID = self:GetActiveRecipeID()
    print(format("GetActiveRecipeID() = %s", tostring(activeRecipeID)))
    if activeRecipeID then
        local itemMap, currencyMap = self:GetReagentRequirementMaps(activeRecipeID)
        local count = 0
        for itemID, qty in pairs(itemMap) do
            count = count + 1
            print(format("  schematic item:     itemID=%d requiredQty=%d", itemID, qty))
        end
        for currID, qty in pairs(currencyMap) do
            count = count + 1
            print(format("  schematic currency: currencyID=%d requiredQty=%d", currID, qty))
        end
        if count == 0 then print("  schematic maps are empty") end
    end

    -- Check count hooks
    local testItemID = 213746 -- Runed Harbinger Crest
    local craftCount = ItemUtil.GetCraftingReagentCount(testItemID)
    local itemCount = C_Item.GetItemCount(testItemID)
    local globalCount = GetItemCount(testItemID)
    print(format("GetCraftingReagentCount(%d) = %s", testItemID, tostring(craftCount)))
    print(format("C_Item.GetItemCount(%d) = %s", testItemID, tostring(itemCount)))
    print(format("GetItemCount(%d) = %s", testItemID, tostring(globalCount)))

    -- Check GetHideUnownedFlags (requires recipeID — use current form's if available)
    if C_TradeSkillUI and C_TradeSkillUI.GetHideUnownedFlags then
        local recipeID = self.orderForm and self.orderForm.transaction and self.orderForm.transaction.recipeID or 0
        local cannotModify, alwaysShow = C_TradeSkillUI.GetHideUnownedFlags(recipeID)
        print(format("GetHideUnownedFlags(%d): cannotModify=%s alwaysShow=%s", recipeID, tostring(cannotModify), tostring(alwaysShow)))
    else
        print("GetHideUnownedFlags: NOT FOUND")
    end

    -- Walk ProfessionsFrame for flyout frames
    local found = 0
    local function walk(frame, depth)
        if not frame or depth > 10 then return end
        local ok, hasBeh = pcall(function() return frame.behavior ~= nil end)
        if ok and hasBeh then
            found = found + 1
            local name = frame:GetName() or frame:GetDebugName() or "unnamed"
            local patched = frame.behavior._cmPatched and "YES" or "NO"
            local enabled = "?"
            pcall(function()
                enabled = tostring(frame.behavior:IsElementEnabled({}, false))
            end)
            print(format("  Flyout[%d]: %s | patched=%s | IsElementEnabled=%s", found, name, patched, enabled))
        end
        local ok2, n = pcall(function() return frame.GetNumChildren and frame:GetNumChildren() or 0 end)
        if ok2 and n > 0 then
            for i = 1, n do
                local ok3, child = pcall(function() return select(i, frame:GetChildren()) end)
                if ok3 and child then walk(child, depth + 1) end
            end
        end
    end
    walk(ProfessionsFrame, 0)
    if found == 0 then print("  No flyout frames found under ProfessionsFrame") end
    print(format("  MCRFlyoutMixin exists: %s", tostring(_G.MCRFlyoutMixin ~= nil)))
    print(format("  OrderMCRFlyoutMixin exists: %s", tostring(_G.OrderMCRFlyoutMixin ~= nil)))

    -- Inspect buttons inside any open flyout ScrollTarget
    local pf = ProfessionsFrame
    local cf = pf and pf.CraftingPage and pf.CraftingPage.SchematicForm
    if cf then
        pcall(function()
            for i = 1, cf:GetNumChildren() do
                local child = select(i, cf:GetChildren())
                local ok, hasBeh = pcall(function() return child.behavior ~= nil end)
                if ok and hasBeh and child.ScrollBox then
                    print("  ScrollBox fields:")
                    for k, v in pairs(child.ScrollBox) do
                        if type(v) ~= "function" then
                            print(format("    ScrollBox.%s = %s", tostring(k), tostring(v))  )
                        end
                    end
                    local target = child.ScrollBox.ScrollTarget
                    if target then
                        print(format("  ScrollTarget children: %d", target:GetNumChildren()))
                        for j = 1, target:GetNumChildren() do
                            local btn = select(j, target:GetChildren())
                            if btn then
                                local enabled = btn.IsEnabled and btn:IsEnabled()
                                local desatIcon = btn.Icon and btn.Icon.GetDesaturated and btn.Icon:GetDesaturated()
                                local hasOnClick = btn.GetScript and btn:GetScript("OnClick") ~= nil
                                print(format("    btn[%d]: IsEnabled=%s desatIcon=%s hasOnClick=%s type=%s",
                                    j, tostring(enabled), tostring(desatIcon), tostring(hasOnClick),
                                    tostring(btn.GetObjectType and btn:GetObjectType())))
                                -- Print all non-function Lua fields and the C-level elementData
                                pcall(function()
                                    print(format("      _cmFlyoutHooked=%s", tostring(btn._cmFlyoutHooked)))
                                    for k, v in pairs(btn) do
                                        local t = type(v)
                                        if t ~= "function" and t ~= "userdata" then
                                            if t == "table" then
                                                print(format("      btn.%s = [table]", tostring(k)))
                                            else
                                                print(format("      btn.%s = %s", tostring(k), tostring(v)))
                                            end
                                        end
                                    end
                                    -- C-level element data (ScrollBox stores it via SetElementData)
                                    local ed = btn.GetElementData and btn:GetElementData()
                                    if ed then
                                        print("      GetElementData() fields:")
                                        for k, v in pairs(ed) do
                                            local t = type(v)
                                            if t ~= "function" and t ~= "userdata" then
                                                if t == "table" then
                                                    print(format("        ed.%s = [table]", tostring(k)))
                                                    -- Expand reagent sub-table
                                                    if k == "reagent" then
                                                        for rk, rv in pairs(v) do
                                                            if type(rv) ~= "function" and type(rv) ~= "userdata" then
                                                                print(format("          reagent.%s = %s", tostring(rk), tostring(rv)))
                                                            end
                                                        end
                                                    end
                                                else
                                                    print(format("        ed.%s = %s", tostring(k), tostring(v)))
                                                end
                                            end
                                        end
                                    else
                                        print("      GetElementData() = nil")
                                    end
                                end)
                            end
                        end
                    else
                        print("  ScrollTarget: NIL (field name may differ)")
                        print("  Trying GetScrollTarget:")
                        pcall(function()
                            local st = child.ScrollBox:GetScrollTarget()
                            print(format("  GetScrollTarget() children: %d", st and st:GetNumChildren() or -1))
                        end)
                    end
                end
            end
        end)
    end
end

-- Re-enable slot buttons that Blizzard grayed out before hooks were applied.
function addon:RefreshReagentSlots()
    local function processSlot(slot)
        if not slot then return end
        local btn = slot.Button or slot
        if not btn then return end
        if not btn._cmHooked and btn.Disable and btn.Enable then
            btn._cmHooked = true
            hooksecurefunc(btn, "Disable", function(s)
                if addon.unlockAllEnabled then
                    s:Enable()
                    if s.Icon then s.Icon:SetDesaturated(false) end
                    if s.SlotBackground then s.SlotBackground:SetDesaturated(false) end
                end
            end)
        end
        if addon.unlockAllEnabled then
            if btn.Enable then btn:Enable() end
            if btn.Icon then btn.Icon:SetDesaturated(false) end
            if btn.SlotBackground then btn.SlotBackground:SetDesaturated(false) end
        end
    end

    local function refreshContainer(container)
        if not container or not container:IsVisible() then return end
        for i = 1, container:GetNumChildren() do
            local child = select(i, container:GetChildren())
            processSlot(child)
            if child and child.GetNumChildren then
                for j = 1, child:GetNumChildren() do
                    processSlot(select(j, child:GetChildren()))
                end
            end
        end
    end

    local pf = ProfessionsFrame
    local cf = pf and pf.CraftingPage and pf.CraftingPage.SchematicForm
    local of = pf and pf.OrdersPage and pf.OrdersPage.OrderView
        and pf.OrdersPage.OrderView.OrderDetails and pf.OrdersPage.OrderView.OrderDetails.SchematicForm
    if cf then
        refreshContainer(cf.Reagents)
        refreshContainer(cf.OptionalReagents)
        refreshContainer(cf.FinishingReagents)
    end
    if of then
        refreshContainer(of.Reagents)
        refreshContainer(of.OptionalReagents)
        refreshContainer(of.FinishingReagents)
    end
end

function addon:ApplyFlyoutOverrides()
    -- Fake item counts so crests/sparks show as available
    if not self:IsHooked(ItemUtil, "GetCraftingReagentCount") then
        self:RawHook(ItemUtil, "GetCraftingReagentCount", "FakeReagentCount", true)
    end
    if ProfessionsUtil and ProfessionsUtil.GetReagentQuantityInPossession
        and not self:IsHooked(ProfessionsUtil, "GetReagentQuantityInPossession") then
        self:RawHook(ProfessionsUtil, "GetReagentQuantityInPossession", "FakeReagentCount", true)
    end
    if not self:IsHooked(C_Item, "GetItemCount") then
        self:RawHook(C_Item, "GetItemCount", "FakeReagentCount", true)
    end
    if not self:IsHooked(_G, "GetItemCount") then
        self:RawHook(_G, "GetItemCount", "FakeReagentCount", true)
    end

    -- GetHideUnownedFlags(recipeID) -> cannotModifyHideUnowned, alwaysShowUnowned
    -- Return false, false: let the flyout use its normal single-panel layout.
    -- Our count hook already returns non-zero for all reagents, so the flyout
    -- treats them as owned and includes them in the normal panel. Returning
    -- alwaysShowUnowned=true would trigger a second "unowned" panel alongside
    -- the normal one, making the flyout appear twice as wide.
    if C_TradeSkillUI and C_TradeSkillUI.GetHideUnownedFlags
        and not self:IsHooked(C_TradeSkillUI, "GetHideUnownedFlags") then
        self:RawHook(C_TradeSkillUI, "GetHideUnownedFlags", function(recipeID)
            if addon.unlockAllEnabled then return false, false end
            return addon.hooks[C_TradeSkillUI]["GetHideUnownedFlags"](recipeID)
        end, true)
    end

    -- Re-enable any slot buttons already drawn with grayed state
    self:RefreshReagentSlots()
end

function addon:BuildReagentCheckbox(parent)
    if not parent then return end
    local checkbox = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    parent.ReagentUnlocker = checkbox
    checkbox:ClearAllPoints()
    checkbox:SetSize(20, 20)
    checkbox.text:SetText(LIGHTGRAY_FONT_COLOR:WrapTextInColorCode("Unlock All"))
    checkbox:SetChecked(false)
    checkbox:Hide()

    function checkbox:Refresh()
        addon.unlockAllEnabled = self:GetChecked() and true or false

        if addon.unlockAllEnabled then
            addon:ApplyFlyoutOverrides()
            addon:SetFlyoutWatcher(true)
        else
            addon:SetFlyoutWatcher(false)
        end

        if ProfessionsFrame.OrdersPage.OrderView:IsVisible() then
            ProfessionsFrame.OrdersPage.OrderView:OnEvent("BAG_UPDATE")
        elseif ProfessionsCustomerOrdersFrame.Form:IsVisible() then
            ProfessionsCustomerOrdersFrame.Form:OnEvent("BAG_UPDATE")
        elseif ProfessionsFrame.CraftingPage.SchematicForm.UpdateAllSlots then
            ProfessionsFrame.CraftingPage.SchematicForm:UpdateAllSlots()
        end

        local container = self:GetParent()
        if container then
            local qDialog = container.QualityDialog
            if qDialog and qDialog.recipeID and qDialog.Setup then qDialog:Setup() end
        end
    end

    checkbox:SetScript("OnClick", function(self) self:Refresh() end)
    checkbox:SetScript("OnHide", function()
        addon:UnhookAll()
        addon:SetFlyoutWatcher(false)
        addon._reagentCache = nil
        -- per-instance behavior patches remain but unlockAllEnabled=false makes them pass through
    end)

    return checkbox
end

-- Return the active recipe ID from whichever crafting form is open.
function addon:GetActiveRecipeID()
    local pf = ProfessionsFrame
    local cf = pf and pf.CraftingPage and pf.CraftingPage.SchematicForm
    if cf and cf.transaction and cf.transaction.recipeID then
        return cf.transaction.recipeID
    end
    local of = pf and pf.OrdersPage and pf.OrdersPage.OrderView
        and pf.OrdersPage.OrderView.OrderDetails
        and pf.OrdersPage.OrderView.OrderDetails.SchematicForm
    if of and of.transaction and of.transaction.recipeID then
        return of.transaction.recipeID
    end
    local form = ProfessionsCustomerOrdersFrame and ProfessionsCustomerOrdersFrame.Form
    if form and form.transaction and form.transaction.recipeID then
        return form.transaction.recipeID
    end
end

-- Build (and cache) two maps for the given recipe:
--   itemMap[itemID]         → quantityRequired  (for item-based reagents)
--   currencyMap[currencyID] → quantityRequired  (for currency-based reagents like crests)
-- The schematic doesn't change between opens of the same recipe, so we only
-- call GetRecipeSchematic once per recipeID.
function addon:GetReagentRequirementMaps(recipeID)
    if self._reagentCache and self._reagentCache.recipeID == recipeID then
        return self._reagentCache.itemMap, self._reagentCache.currencyMap
    end
    local itemMap, currencyMap = {}, {}
    local ok, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
    if ok and schematic and schematic.reagentSlotSchematics then
        for _, slot in ipairs(schematic.reagentSlotSchematics) do
            local qty = slot.quantityRequired or 1
            if slot.reagents then
                for _, reagent in ipairs(slot.reagents) do
                    if reagent.itemID then
                        itemMap[reagent.itemID] = qty
                    end
                    if reagent.currencyID then
                        currencyMap[reagent.currencyID] = qty
                    end
                end
            end
        end
    end
    self._reagentCache = {recipeID = recipeID, itemMap = itemMap, currencyMap = currencyMap}
    return itemMap, currencyMap
end

-- Replace all count APIs with the exact quantity the recipe requires.
-- GetCraftingReagentCount/GetItemCount pass a plain itemID (number).
-- GetReagentQuantityInPossession passes a reagentData table with .itemID or .currencyID.
-- Both cases are handled here so every count display shows the required quantity.
function addon:FakeReagentCount(arg1)
    local recipeID = self:GetActiveRecipeID()
    if recipeID then
        local itemMap, currencyMap = self:GetReagentRequirementMaps(recipeID)
        local qty
        if type(arg1) == "number" then
            qty = itemMap[arg1]
        elseif type(arg1) == "table" then
            qty = (arg1.itemID and itemMap[arg1.itemID])
               or (arg1.currencyID and currencyMap[arg1.currencyID])
        end
        if qty then return qty end
    end
    return 999
end

function addon:GetUnlockedOperationInfo(details)
    if not self.unlockAllEnabled then return end

    local form = details and details:GetParent()
    local transaction = form and form.transaction
    local recipeID = transaction and transaction.recipeID
    if not recipeID or not transaction.CreateCraftingReagentInfoTbl then return end

    local reagents = transaction:CreateCraftingReagentInfoTbl() or {}

    local isRecraft = false
    if transaction.IsRecraft then
        pcall(function() isRecraft = transaction:IsRecraft() end)
    end

    local crafting
    if isRecraft and C_TradeSkillUI.GetCraftingOperationInfoForRecraft then
        local ok, result = pcall(C_TradeSkillUI.GetCraftingOperationInfoForRecraft, recipeID, reagents, nil)
        if ok then crafting = result end
    end
    if not crafting or (crafting.baseSkill or 0) == 0 then
        local ok, result = pcall(C_TradeSkillUI.GetCraftingOperationInfo, recipeID, reagents)
        if ok then crafting = result end
    end

    if crafting and (crafting.baseSkill or 0) > 0 then return crafting end
end

function addon:ShowSkillDetails(details)
    if not details or not details.operationInfo or not details.statLinePool then return end

    local unlockedInfo = self:GetUnlockedOperationInfo(details)
    local operationInfo = unlockedInfo or details.operationInfo

    for line, _ in details.statLinePool:EnumerateActive() do
        if line.LeftLabel:GetText() == PROFESSIONS_CRAFTING_STAT_TT_CRIT_HEADER then
            local text = self:FormatInfoDetails(operationInfo)
            if unlockedInfo then text = "|cffffcc00[+Crest]|r " .. (text or "") end
            line.RightLabel:SetText(text)
            break
        end
    end
end

function addon:FormatCrafterInfo(entry, hideName)
    local info = entry.info
    local display = info and self:FormatInfoDetails(info) or "|cFF999999???|r"
    return entry.crafter and not hideName and format("%s - %s", entry.crafter, display) or display
end

function addon:FormatInfoDetails(info)
    if not info then return end
    if info.learned == "notloaded" then return "|cff999999not loaded|r" end
    if info.learned == "notlearned" then return "|cffff0000not learned|r" end
    if not info.isQualityCraft then return "|cff00ff00ok|r" end

    local skill = info.baseSkill + info.bonusSkill
    local percent, bonus

    for _, stat in pairs(info.bonusStats) do
        if stat.bonusStatName == PROFESSIONS_CRAFTING_STAT_TT_CRIT_HEADER then
            percent, bonus = string.match(stat.ratingDescription, "([0-9]+%.?[0-9]+)%%[^0-9]+([0-9]+)")
            break
        end
    end

    if not (percent and bonus and skill) then return end

    local threshold = skill - info.upperSkillTreshold + (skill < info.upperSkillTreshold and bonus or 0)
    local baseQual = info.craftingQuality
    local procQual = min(info.guaranteedCraftingQualityID <= 3 and 3 or 5, baseQual + (threshold >= 0 and 1 or 0))

    local icon = format("|A:%s:16:16|a", Professions.GetIconForQuality(procQual, true))
    local nextIcon = format("|A:%s:16:16|a", Professions.GetIconForQuality(min(5, procQual + 1), true))

    local thresholdText = (threshold < 0 and format("(|cffff0000%d|r to %s)", threshold, nextIcon))
        or (threshold >= 0 and format("(|cff00ff00+%d|r)", threshold))

    return (baseQual == procQual and format("%s%s", icon, thresholdText))
        or format("%.1f%% to %s%s", percent, icon, thresholdText)
end

function addon:TableEquals(t1, t2, ignoreMeta)
    local ty1, ty2 = type(t1), type(t2)
    if ty1 ~= ty2 then return false end
    if ty1 ~= 'table' then return t1 == t2 end

    local mt = getmetatable(t1)
    if not ignoreMeta and mt and mt.__eq then return t1 == t2 end

    for k, v in pairs(t1) do
        if t2[k] == nil or not self:TableEquals(v, t2[k]) then return false end
    end
    for k, v in pairs(t2) do
        if t1[k] == nil or not self:TableEquals(t1[k], v) then return false end
    end
    return true
end

CraftersMark:OnInitialize()
