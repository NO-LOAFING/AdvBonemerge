TOOL.Category = "Constraints"
TOOL.Name = "Advanced Bonemerge"
TOOL.Command = nil
TOOL.ConfigName = "" 

TOOL.ClientConVar.matchnames = "1"
TOOL.ClientConVar.drawhalo = "1"
TOOL.ClientConVar.bone_hierarchyview = "0"
TOOL.ClientConVar.bone_ids = "1"
TOOL.ClientConVar.bone_linkicons = "0"

TOOL.Information = {
	{name = "info1", stage = 1, icon = "gui/info.png"},
	{name = "left1", stage = 1, icon = "gui/lmb.png"},
	{name = "right01", icon = "gui/rmb.png"},
	{name = "rightuse01", icon = "gui/rmb.png", icon2 = "gui/e.png"},
	//{name = "reload01", icon = "gui/r.png"},
}

if CLIENT then
	language.Add("tool.advbonemerge.name", "Advanced Bonemerge")
	language.Add("tool.advbonemerge.desc", "Attach models to things and customize how they're attached")
	//language.Add("tool.advbonemerge.help", "bonemerging is pretty great")

	language.Add("tool.advbonemerge.info1", "Use the context menu to edit attached models")
	language.Add("tool.advbonemerge.left1", "Attach models to the selected object")
	language.Add("tool.advbonemerge.right01", "Select an object to attach models to")
	language.Add("tool.advbonemerge.rightuse01", "Select yourself")
	//language.Add("tool.advbonemerge.reload01", "I don't think we'll be using reload for this tool")

	language.Add("undone_AdvBonemerge", "Undone Advanced Bonemerge")
end




local ConstraintsToPreserve = {
	AdvBoneMerge = true,
	AttachParticleControllerBeam = true, //Advanced Particle Controller addon
	PartCtrl_Ent = true, //ParticleControlOverhaul
	PartCtrl_SpecialEffect = true, //ParticleControlOverhaul
	BoneMerge = true, //Bone Merger addon
	EasyBonemerge = true, //Easy Bonemerge Tool addon
	CompositeEntities_Constraint = true, //Composite Bonemerge addon
}

if SERVER then

	function CreateAdvBonemergeEntity(target, parent, ply, alwaysreplace, keepparentempty, matchnames)

		if !IsValid(target) or target:IsPlayer() or target:IsWorld() or !IsValid(parent) or target == parent or !util.IsValidModel(target:GetModel()) then return end
		if parent.AttachedEntity then parent = parent.AttachedEntity end

		if (target:GetClass() == "prop_animated" and target:GetBoneName(0) != "static_prop") and !alwaysreplace then

			//prop_animated can handle adv bonemerge functionality by itself, so we don't need to replace the entity
			local newent = target

			//prop_animated already has a BoneInfo table, but we need to update it
			newent:CreateAdvBoneInfoTable(parent, keepparentempty, matchnames)
			//Make sure the clients get the new boneinfo table
			net.Start("AdvBone_EntBoneInfoTableUpdate_SendToCl")
				net.WriteEntity(newent)
			net.Broadcast()

			//We don't want the entity to have physics if it's parented
			newent:PhysicsDestroy()

			AdvBoneExposeBonesToClient(newent) //is this necessary for animprops?
			return newent

		end

		//More special handling for animated props: when "disabling" them (converting them to ent_advbonemerge), 
		//convert their custom eye posing method (point relative to entity) to the more standard method used by ent_advbonemerge (point relative to eyes)
		if target:GetClass() == "prop_animated" and target.EntityMods and target.EntityMods.eyetarget and target.EyeTargetLocal then
			local eyetargetpos = LocalToWorld(target.EyeTargetLocal, Angle(), target:GetPos(), target:GetAngles())
			local eyeattach = target:GetAttachment(target:LookupAttachment("eyes"))
			if eyeattach then
				newtargetpos = WorldToLocal(eyetargetpos, Angle(), eyeattach.Pos, eyeattach.Ang)
				target.EntityMods.eyetarget.EyeTarget = newtargetpos
			end
		end


		local oldent = target
		if oldent.AttachedEntity then oldent = oldent.AttachedEntity end


		local newent = ents.Create("ent_advbonemerge")
		newent:SetPos(parent:GetPos())
		newent:SetAngles(parent:GetAngles())

		//Copy all of oldent's information to newent
		newent:SetModel(oldent:GetModel())
		newent:SetSkin(oldent:GetSkin() or 0)
		//Copy bodygroups
		if oldent:GetNumBodyGroups() then
			for i = 0, oldent:GetNumBodyGroups() - 1 do
				newent:SetBodygroup(i, oldent:GetBodygroup(i)) 
			end
		end
		//Copy flexes - people should probably be using the cosmetic face poser fix instead but hey let's keep it compatible anyway
		if oldent:HasFlexManipulatior() then
			newent:SetFlexScale(oldent:GetFlexScale())
			for i = 0, oldent:GetFlexNum() - 1 do 
				newent:SetFlexWeight(i, oldent:GetFlexWeight(i)) 
			end
		end
		//Copy bonemanips
		//local hasscalemanip = false
		newent.AdvBone_BoneManips = {} //this gets repopulated by ManipulateBoneX funcs below
		for i = -1, oldent:GetBoneCount() - 1 do
			if oldent:GetManipulateBonePosition(i) != vector_origin then newent:ManipulateBonePosition(i, oldent:GetManipulateBonePosition(i), false) end //don't network these to the client yet; the ent's networking funcs will handle it
			if oldent:GetManipulateBoneAngles(i) != angle_zero then newent:ManipulateBoneAngles(i, oldent:GetManipulateBoneAngles(i), false) end
			if oldent:GetManipulateBoneScale(i) != Vector(1,1,1) then newent:ManipulateBoneScale(i, oldent:GetManipulateBoneScale(i), false) --[[hasscalemanip = true]] end
			//newent:ManipulateBoneJiggle(i, oldent:GetManipulateBoneJiggle(i))  //broken?
		end
		//Copy over DisableBeardFlexifier, just in case we're an unmerged ent that inherited this value
		newent:SetNWBool("DisableBeardFlexifier", oldent:GetNWBool("DisableBeardFlexifier"))
		//Store a value if we're a merged ParticleControlOverhaul grip point
		newent:SetPartCtrl_MergedGrip(oldent.PartCtrl_Grip)

		//Create a BoneInfo table - this is used to store bone manipulation info other than the standard Position/Angle/Scale values already available by default
		local boneinfo = {}
		for i = -1, oldent:GetBoneCount() - 1 do
			local newsubtable = {
				parent = "",
				//scale = !hasscalemanip, //If the ent we converted has any scale manips, then turn this off by default so the manips look the same as they did before
				scale = true //never mind, the above functionality is unintuitive, and just leaves people wondering why "scale with target" is defaulting to false
			}

			if target.AdvBone_BoneInfo and target.AdvBone_BoneInfo[i] then
				newsubtable.scale = target.AdvBone_BoneInfo[i].scale
			end

			if !keepparentempty then
				if target.AdvBone_BoneInfo and target.AdvBone_BoneInfo[i]
				and ( parent:LookupBone( target.AdvBone_BoneInfo[i].parent ) or target.AdvBone_BoneInfo[i].parent == "" ) then
					//If oldent was unmerged and already has a BoneInfo table for us to use, then get the value from it, but only if the listed target bone exists/is an empty string
					newsubtable.parent = target.AdvBone_BoneInfo[i].parent
				elseif matchnames and i != -1 and parent:LookupBone( oldent:GetBoneName(i) ) then
					newsubtable.parent = string.lower( oldent:GetBoneName(i) )
				end
			end

			//TODO: If this entity has an adv particle controller effect or beam attached to the model origin and the root bone is attached above, then attach this entity's 
			//origin relative to the same bone so the effect is in the same place?

			boneinfo[i] = newsubtable
		end
		//MsgN(target)
		if !target.AdvBone_BoneInfo then
			//This value is removed if the boneinfo table is modified or the entity is saved. If the entity is unmerged without the boneinfo table being changed from the default,
			//it won't save the table, so if the player used the wrong matchnames setting by mistake, they won't be stuck with the table it generated and can just unmerge it, 
			//change the setting, and merge it again to generate a new one.
			//MsgN("CreateAdvBonemergeEntity detects no boneinfo table, setting IsDefault to true")
			newent.AdvBone_BoneInfo_IsDefault = true
		elseif target.AdvBone_BoneInfo_IsDefault != nil then
			//prop_animated has an IsDefault value, and we want it to carry over when it's disabled and converted into an ent_advbonemerge
			//MsgN("CreateAdvBonemergeEntity detects IsDefault on target, setting IsDefault to ", target.AdvBone_BoneInfo_IsDefault)
			newent.AdvBone_BoneInfo_IsDefault = target.AdvBone_BoneInfo_IsDefault
		end
		newent.AdvBone_BoneInfo = boneinfo

		//Save a big table of entity info to newent that we can use to reconstruct the oldent with newent's Unmerge function
		local unmergeinfo = table.Copy( duplicator.CopyEntTable(target) )  //use target and not oldent - we don't want to copy the AttachedEntity of a prop_effect
		newent.AdvBone_UnmergeInfo = unmergeinfo

		//Spawn the entity and then apply entity modifiers - we need to spawn the entity for these to work, so do these last
		newent:Spawn()
		newent.EntityMods = oldent.EntityMods
		newent.BoneMods = oldent.BoneMods
		duplicator.ApplyEntityModifiers(ply, newent)
		duplicator.ApplyBoneModifiers(ply, newent)


		//Get all of the constraints directly attached to target that we DON'T want to convert into new bonemerges. Copy them over to newent.
		local targetconsts = constraint.GetTable(target)
		for k, const in pairs (targetconsts) do
			if const.Entity then
				if ConstraintsToPreserve[const.Type] then
					//PrintTable(const)

					//If any of the values in the constraint table are target, switch them over to newent
					for key, val in pairs (const) do
						if val == target then 
							const[key] = newent
						//Transfer over bonemerged ents from other addons' bonemerge constraints, and make sure they don't get DeleteOnRemoved
						elseif (const.Type == "EasyBonemerge" or const.Type == "CompositeEntities_Constraint" 
						or const.Type == "PartCtrl_Ent" or const.Type == "PartCtrl_SpecialEffect") //doesn't work for BoneMerge, bah
						and isentity(val) and IsValid(val) and val:GetParent() == target then
							//MsgN("reparenting ", val:GetModel(), " ", val, " to ", newent)
							if const.Type == "CompositeEntities_Constraint" then
								val:SetParent(newent)
							elseif const.Type == "PartCtrl_SpecialEffect" then
								val:SetParent(newent)
								val:SetSpecialEffectParent(newent)
							end
							target:DontDeleteOnRemove(val)
						end
					end

					local entstab = {}

					//Also switch over any instances of target to newent inside the entity subtable
					for tabnum, tab in pairs (const.Entity) do
						if tab.Entity and tab.Entity == target then 
							const.Entity[tabnum].Entity = newent
							const.Entity[tabnum].Index = newent:EntIndex()
						end
						entstab[const.Entity[tabnum].Index] = const.Entity[tabnum].Entity
					end

					if const.Type == "PartCtrl_Ent" or const.Type == "PartCtrl_SpecialEffect" and IsValid(const.Ent1) then
						target:DontDeleteOnRemove(const.Ent1) //Make sure we also clear deleteonremove for unparented cpoints
					end

					//MsgN("")

					//Now copy the constraint over to newent
					duplicator.CreateConstraintFromTable(const, entstab)
				end
			end
		end
		//Unbreak all ParticleControlOverhaul fx attached to the ent or any of its children
		if PartCtrl_RefreshAllChildFx then 
			timer.Simple(0.1, function() //do this on a timer, otherwise the advbonemerge ent might not exist on the client yet when they receive the new table
				PartCtrl_RefreshAllChildFx(newent)
			end)
		end


		AdvBoneExposeBonesToClient(newent)
		return newent

	end

end




function TOOL:LeftClick(trace)

	local par = self:GetWeapon():GetNWEntity("AdvBone_CurEntity")

	if trace.HitNonWorld and IsValid(trace.Entity) and !(trace.Entity:IsPlayer()) and IsValid(par) and trace.Entity != par then

		if CLIENT then return true end

		local ply = self:GetOwner()
		local matchnames = (self:GetClientNumber("matchnames") == 1)

		local newent = CreateAdvBonemergeEntity(trace.Entity, par, ply, false, false, matchnames)
		if !IsValid(newent) then return end


		//"Merge via constraint":
		//Get all of the entities directly and indirectly constrained to trace.Entity, not including the ones connected by those same constraints we searched for earlier.
		//Bonemerge them to newent, and use ManipulateBonePosition/Angle to store their pos/ang offsets relative to newent.

		local function GetAllConstrainedEntitiesExceptCertainConstraints(ent, ResultTable)  //best function name ever
			local ResultTable = ResultTable or {}
	
			if ( !IsValid( ent ) ) then return end
			if ( ResultTable[ ent ] ) then return end
	
			ResultTable[ ent ] = ent
	
			local ConTable = constraint.GetTable( ent )
	
			for k, con in ipairs( ConTable ) do
				if !ConstraintsToPreserve[con.Type] then
					for EntNum, Ent in pairs( con.Entity ) do
						GetAllConstrainedEntitiesExceptCertainConstraints( Ent.Entity, ResultTable )
					end
				end
			end

			return ResultTable
		end

		local constrainedents = GetAllConstrainedEntitiesExceptCertainConstraints(trace.Entity)
		constrainedents[trace.Entity] = nil
		constrainedents[newent] = nil
		constrainedents[par] = nil

		for _, oldent2 in pairs (constrainedents) do
			if oldent2 != trace.Entity and oldent2 != newent and oldent2 != par then
				local newent2 = CreateAdvBonemergeEntity(oldent2, newent, ply, false, true, matchnames)  //create the bonemerge entity, copy over those constraints, etc., but keep the boneinfo table empty

				if newent2 then

					//set newent2's bone manips so that the pos and ang manips match oldent2's position and angle offset from the parent entity

					if trace.Entity:GetClass() == "prop_animated" then
						//If the parent entity is an animated prop, then attach to its origin since the animation will be moving the root bone around
						local pos, ang = WorldToLocal(oldent2:GetPos(), oldent2:GetAngles(), trace.Entity:GetPos(), trace.Entity:GetAngles())
						local origin = -1
						if newent2:GetBoneName(0) == "static_prop" then origin = 0 end
						newent2:ManipulateBonePosition(origin,pos)
						newent2:ManipulateBoneAngles(origin,ang)
					else
						//if the parent entity is anything else, then attach to its root bone like a normal bonemerge via constraint
						local bonepos, boneang = nil, nil
						local matr = trace.Entity:GetBoneMatrix(0)
						if matr then 
							bonepos, boneang = matr:GetTranslation(), matr:GetAngles() 
						else
							bonepos, boneang = trace.Entity:GetBonePosition(0) 
						end
						local pos, ang = WorldToLocal(oldent2:GetPos(), oldent2:GetAngles(), bonepos, boneang)
						local origin = -1
						if newent2:GetBoneName(0) == "static_prop" then origin = 0 end
						newent2.AdvBone_BoneInfo[origin].parent = trace.Entity:GetBoneName(0)
						newent2:ManipulateBonePosition(origin,pos)
						newent2:ManipulateBoneAngles(origin,ang)
					end
					//We've modified the boneinfo table, so it's not default - save it on unmerge
					newent2.AdvBone_BoneInfo_IsDefault = false

					//Apply the adv bonemerge constraint
					constraint.AdvBoneMerge(newent, newent2, ply)
					if !(oldent2:GetClass() == "prop_animated" and oldent2:GetBoneName(0) != "static_prop") then
						oldent2:Remove()
					end

				end
			end
		end


		//Apply the adv bonemerge constraint
		local const = constraint.AdvBoneMerge(par, newent, ply)

		//Add an undo entry
		undo.Create("AdvBonemerge")
			undo.AddEntity(const)  //the constraint entity will unmerge newent upon being removed
			undo.SetPlayer(ply)
		local nodename = newent:GetModel()
		if (newent.GetPartCtrl_MergedGrip and newent:GetPartCtrl_MergedGrip()) then
			//Merged particle effects display the name of the particle instead
			nodename = "particle" //placeholder in case this fails somehow
			local tab = constraint.FindConstraint(newent, "PartCtrl_Ent")
			if istable(tab) and IsValid(tab.Ent1) and tab.Ent1.PartCtrl_Ent then
				nodename = tab.Ent1:GetParticleName()
			else
				local tab = constraint.FindConstraint(newent, "PartCtrl_SpecialEffect")
				if istable(tab) and IsValid(tab.Ent1) and tab.Ent1.PartCtrl_SpecialEffect then
					nodename = tab.Ent1.PrintName
				end
			end
		end
		undo.Finish("Adv. Bonemerge (" .. nodename .. ")")

		//Tell the client to add the new model to the controlpanel's model list - do this on a timer so the entity isn't still null on the client's end
		timer.Simple(0.1, function()
			if !IsValid(newent) then return end
			net.Start("AdvBone_NewModelToCPanel_SendToCl")
				net.WriteEntity(newent)
				//sometimes, if we unmerge and remerge an ent with a custom name, it won't have made it to the client yet
				//when we create the node, so send the custom name again here just to be sure the client gets it in time.
				net.WriteString(newent:GetNWString("AdvBone_CustomName", ""))
			net.Send(ply)
		end)

		if !(trace.Entity:GetClass() == "prop_animated" and trace.Entity:GetBoneName(0) != "static_prop") then
			trace.Entity:Remove()
		end

		return true

	end

end

if SERVER then
	util.AddNetworkString("AdvBone_NewModelToCPanel_SendToCl")
end

if CLIENT then
	//If we received a new entity, then add it to the controlpanel's list
	net.Receive("AdvBone_NewModelToCPanel_SendToCl", function()
		local ent = net.ReadEntity()
		local str = net.ReadString()

		local panel = controlpanel.Get("advbonemerge")
		if !panel or !panel.modellist then return end
		if !IsValid(ent) then return end

		//If you merge, unmerge, then merge again an animprop without opening the menu between them, it'll add a duplicate node unless we check for this. 
		//For some reason, this doesn't happen with normal merged ents, because the original node gets removed on unmerge somewhere i can't figure out - 
		//in fact, doing this check with normal ents can give false positives sometimes and prevent any node from being added at all.
		if IsValid(panel.modellist.AllNodes[ent:EntIndex()]) and ent:GetClass() == "prop_animated" then return end 

		local parent = ent:GetParent()
		if parent.AttachedEntity then parent = parent.AttachedEntity end
		if !IsValid(parent) then return end
		if !panel.modellist.AllNodes[parent:EntIndex()] then return end
		
		if str != "" then ent:SetNWString("AdvBone_CustomName", str) end
		panel.modellist.AddModelNodes(ent, panel.modellist.AllNodes[parent:EntIndex()])
	end)
end



function TOOL:RightClick(trace)

	if CLIENT then return true end

	//Select self by holding E
	if self:GetOwner():KeyDown(IN_USE) then 
		trace.Entity = self:GetOwner()
	end

	if IsValid(trace.Entity) then
		self:GetWeapon():SetNWEntity("AdvBone_CurEntity", trace.Entity)
		AdvBoneExposeBonesToClient(trace.Entity)
	else
		self:GetWeapon():SetNWEntity("AdvBone_CurEntity", NULL)
	end

	return true

end




function TOOL:Think()

	if CLIENT then

		local ent = self:GetWeapon():GetNWEntity("AdvBone_CurEntity")

		local panel = controlpanel.Get("advbonemerge")
		if !panel or !panel.modellist then return end

		//Update the modellist in the controlpanel if CurEntity has changed
		panel.CurEntity = panel.CurEntity or NULL
		if panel.CurEntity != ent:EntIndex() then
			panel.CurEntity = ent:EntIndex()
			panel.modellist.PopulateModelList(ent)
		end

	end

end

function TOOL:GetStage()

	local ent = self:GetWeapon():GetNWEntity("AdvBone_CurEntity")

	if IsValid(ent) then
		return 1
	else
		return 0
	end

end




if CLIENT then

	local colorborder = Color(0,0,0,255)
	local colorselect = Color(0,255,0,255)
	local colorunselect = Color(255,255,255,255)
	local cv_halo //the convar won't exist until a bit later, when the toolgun code reads the TOOL.ClientConVar tab and creates them, so don't cache the convar until after we've selected an ent

	local function AdvBone_DoHUDPaint()
		//Don't run this func more than once per frame
		local curtime = CurTime()
		AdvBone_DoHUDPaint_LastRunTime = AdvBone_DoHUDPaint_LastRunTime or curtime
		if AdvBone_DoHUDPaint_LastRunTime >= curtime then return end
		AdvBone_DoHUDPaint_LastRunTime = curtime

		if g_ContextMenu and g_ContextMenu:IsVisible() then
			local panel = controlpanel.Get("advbonemerge")
			if !panel or !panel.bonelist then return end
			local ent = LocalPlayer():GetWeapon("gmod_tool")
			if IsValid(ent) then
				if ent:GetMode() != "advbonemerge" then return end
				ent = ent:GetNWEntity("AdvBone_CurEntity")
			end
			local bonemanipent = panel.modellist.selectedent

			if IsValid(ent) then
				local hov = vgui:GetHoveredPanel()

				cv_halo = cv_halo or GetConVar("advbonemerge_drawhalo")
				if cv_halo and cv_halo:GetBool() then
					//Draw a halo around the entity we're manipulating the bones of
					local animcolor = 189 + math.cos(RealTime() * 4) * 17
					if ent.AttachedEntity then ent = ent.AttachedEntity end
					if IsValid(bonemanipent) and ent != bonemanipent then
						halo.Add({bonemanipent}, Color(animcolor, 255, animcolor, 255), 2.3, 2.3, 1, true, false)
					else
						halo.Add({ent}, Color(255, 255, animcolor, 255), 2.3, 2.3, 1, true, false)
					end

					//Also, if we're hovering over an entity in the modellist, draw a
					//different halo around it (much more visible, copied from context menu)
					if IsValid(hov) and IsValid(hov.AdvBone_EntHoverData) then
						local c = Color( 255, 255, 255, 255 )
						c.r = 200 + math.sin( RealTime() * 50 ) * 55
						c.g = 200 + math.sin( RealTime() * 20 ) * 55
						c.b = 200 + math.cos( RealTime() * 60 ) * 55
						halo.Add( {hov.AdvBone_EntHoverData}, c, 2, 2, 2, true, false )
					end
				end

				//If we're hovering over an unselected bone in the bonelist or targetbonelist, draw 
				//its name and position; do this first so that the selected bones draw on top of it
				if IsValid(hov) and istable(hov.AdvBone_BoneHoverData) then
					if IsValid(hov.AdvBone_BoneHoverData.ent) and hov.AdvBone_BoneHoverData.id != nil then
						local _pos = nil
						local _name = ""

						if hov.AdvBone_BoneHoverData.id == -1 then
							_pos = hov.AdvBone_BoneHoverData.ent:GetPos()
							_name = "(origin)"
						else
							local matr = hov.AdvBone_BoneHoverData.ent:GetBoneMatrix(hov.AdvBone_BoneHoverData.id)
							if matr then 
								_pos = matr:GetTranslation() 
							else
								_pos = hov.AdvBone_BoneHoverData.ent:GetBonePosition(hov.AdvBone_BoneHoverData.id) 
							end
							_name = hov.AdvBone_BoneHoverData.ent:GetBoneName(hov.AdvBone_BoneHoverData.id)
						end

						if _pos then
							local _pos = _pos:ToScreen()
							local textpos = {x = _pos.x+5,y = _pos.y-5}
							
							draw.RoundedBox(0,_pos.x - 2,_pos.y - 2,4,4,colorborder)
							draw.RoundedBox(0,_pos.x - 1,_pos.y - 1,2,2,colorunselect)
							draw.SimpleTextOutlined(_name,"Default",textpos.x,textpos.y,colorunselect,TEXT_ALIGN_LEFT,TEXT_ALIGN_BOTTOM,1,colorborder)
						end
					end
				end

				//Draw the name and position of all bones currently selected in the bonelist
				if !IsValid(bonemanipent) then return end
				for _, line in pairs (panel.bonelist:GetSelected()) do
					local _pos = nil
					local _name = ""

					if line.id == -1 then
						_pos = bonemanipent:GetPos()
						_name = "(origin)"
					else
						local matr = bonemanipent:GetBoneMatrix(line.id)
						if matr then 
							_pos = matr:GetTranslation() 
						else
							_pos = bonemanipent:GetBonePosition(line.id) 
						end
						_name = bonemanipent:GetBoneName(line.id)
					end

					if !_pos then continue end
					local _pos = _pos:ToScreen()
					local textpos = {x = _pos.x+5,y = _pos.y-5}

					draw.RoundedBox(0,_pos.x - 3,_pos.y - 3,6,6,colorborder)
					draw.RoundedBox(0,_pos.x - 1,_pos.y - 1,2,2,colorselect)
					draw.SimpleTextOutlined(_name,"Default",textpos.x,textpos.y,colorselect,TEXT_ALIGN_LEFT,TEXT_ALIGN_BOTTOM,2,colorborder)
				end
			end
		end
	end

	//Ideally, we want to use the HUDPaint hook for this, so that it doesn't stop displaying when the player switches to 
	//another weapon. However, if another addon breaks the HUDPaint hook by returning false in its own hook function, then 
	//this won't run at all, so use TOOL.DrawHUD as a fallback. One addon that causes this problem is an abandonware legacy 
	//addon commonly used by scenebuilders called Scenic Dispenser, so we can't just tell the creator of the addon to fix it.
	hook.Add("HUDPaint", "AdvBone_HUDPaint_ToolSelection", AdvBone_DoHUDPaint)
	TOOL.DrawHUD = AdvBone_DoHUDPaint

end




if SERVER then

	function constraint.AdvBoneMerge( Ent1, Ent2, ply )

		if !Ent1 or !Ent2 then return end
		
		//create a dummy ent for the constraint functions to use
		local Constraint = ents.Create("info_target")//("logic_collision_pair")
		Constraint:Spawn()
		Constraint:Activate()

		//If the constraint is removed by an Undo, unmerge the second entity - this shouldn't do anything if the constraint's removed some other way i.e. one of the ents is removed
		timer.Simple(0.1, function()  //CallOnRemove won't do anything if we try to run it now instead of on a timer
			if Constraint:GetTable() then  //CallOnRemove can error if this table doesn't exist - this can happen if the constraint is removed at the same time it's created for some reason
				Constraint:CallOnRemove("AdvBone_UnmergeOnUndo", function(Constraint,Ent2,ply)
					//NOTE: if we use the remover tool to get rid of ent1, it'll still be valid for a second, so we need to look for the NoDraw and MoveType that the tool sets the ent to instead.
					//this might have a few false positives, but i don't think that many people will be bonemerging stuff to invisible, intangible ents a whole lot anyway so it's not a huge deal
					if !IsValid(Constraint) or !IsValid(Ent1) or Ent1:IsMarkedForDeletion() or (Ent1:GetNoDraw() == true and Ent1:GetMoveType() == MOVETYPE_NONE) or !IsValid(Ent2) or Ent2:IsMarkedForDeletion() or !IsValid(ply) or !Ent2.Unmerge then return end
					//this doesn't play well with animprops or loading saves, not worth the trouble
					--[[local unmerge = Ent2:Unmerge(ply)
					MsgN("Unmerged: ", unmerge)
					if !unmerge then
						timer.Simple(0.1, function()
							//Send a different notification if the ent failed to unmerge - this isn't as pretty as doing it via the tool's cpanel because the "Undone Advanced Bonemerge"
							//notification will still appear as if it succeeded, but at least if we send the error notification too, the player will know what's going on
							if IsValid(Ent1) and IsValid(Ent2) then //Try not to do this when cleaning up the whole map (i.e. loading a save)
								ply:SendLua("GAMEMODE:AddNotify('Cannot unmerge this entity', NOTIFY_ERROR, 5)")
								ply:SendLua("surface.PlaySound('buttons/button11.wav')")
							end
						end)
					end]]
					Ent2:Unmerge(ply)
				end, Ent2, ply)
			end
		end)
		
		Ent2:SetPos(Ent1:GetPos())
		Ent2:SetAngles(Ent1:GetAngles())
		Ent2:SetParent(Ent1)
		Ent2:FollowBone(Ent1,Ent1:GetBoneCount() - 1)
		if Ent2:GetClass() == "prop_animated" then Ent2:UpdateAnimpropPhysics() end  //destroy the physics object and do a few other necessary things
		//Ent1:DeleteOnRemove(Ent2)

		//Save a reference to the constraint entity, this is used by prop_animated when unmerged
		Ent2.AdvBone_ConstraintEnt = Constraint

		AdvBoneSetLightingOrigin(Ent1,Ent2)

		constraint.AddConstraintTable( Ent1, Constraint, Ent2 )
		
		local ctable  = 
		{
			Type  = "AdvBoneMerge",
			Ent1  = Ent1,
			Ent2  = Ent2,
			ply   = ply,
		}
	
		Constraint:SetTable( ctable )
	
		return Constraint

	end
	duplicator.RegisterConstraint("AdvBoneMerge", constraint.AdvBoneMerge, "Ent1", "Ent2", "ply")


	function AdvBoneSetLightingOrigin(Ent1,Ent2)

		//Keep going up the parenting hierarchy until we get to the one at the top that isn't parented.
		local function GetTopmostParent(ent)
			if !IsValid(ent) then return end
			local ent2 = ent:GetParent()
			if !IsValid(ent2) then
				return ent
			else
				return GetTopmostParent(ent2)
			end
		end
		local lightingent = GetTopmostParent(Ent1)

		//Make the bonemerged ent use the topmost parent's lighting instead of its own.
		local name = lightingent:GetName()
		if name == "" or string.StartWith(name, "AdvBone_LightingOrigin ") then
			name = "AdvBone_LightingOrigin " .. tostring(lightingent)
			lightingent:SetName(name) //if the ent doesn't have a name, then we'll have to give it a crappy placeholder one so that ent:Fire() can target it
			lightingent.AdvBone_PlaceholderName = true  //we can't remove the placeholder name here or ent:Fire() won't work, so we'll have to tell the ent_advbonemerge's
		end						    //serverside think to do it instead
		Ent2:Fire("SetLightingOrigin", name)

		//Now get everything already bonemerged to Ent2 and change their lighting origin from Ent2 to the topmost parent.
		local function GetAllAdvBonemergedEntities(ent, ResultTable)
			local ResultTable = ResultTable or {}
	
			if ( !IsValid( ent ) ) then return end
			if ( ResultTable[ ent ] ) then return end
	
			ResultTable[ ent ] = ent
	
			local ConTable = constraint.GetTable(ent)
	
			for k, con in ipairs( ConTable ) do
				if con.Type == "AdvBoneMerge" then
					for EntNum, Ent in pairs( con.Entity ) do
						GetAllAdvBonemergedEntities(Ent.Entity, ResultTable)
					end
				end
			end

			return ResultTable
		end
		local tab = GetAllAdvBonemergedEntities(Ent2)
		for _, Ent3 in pairs (tab) do
			Ent3:Fire("SetLightingOrigin", name)
		end

	end


	function AdvBoneExposeBonesToClient(ent)  //serverside only, ironically
		//Have a dummy ent use FollowBone to expose all of the entity's bones. If we don't do this, a whole bunch of bones can return as invalid clientside.
		if ent.AttachedEntity then ent = ent.AttachedEntity end
		local lol = ents.Create("base_point")
		if IsValid(lol) then
			lol:SetPos(ent:GetPos())
			lol:SetAngles(ent:GetAngles())
			lol:FollowBone(ent,ent:GetBoneCount() - 1)
			lol:Spawn()
			lol:Remove() //We don't need the ent to stick around. All we needed was for it to use FollowBone once.
		end
	end

end




//note 10/15/14: this is now duplicated code in both advbone and animpropoverhaul, lame
//(used by cpanel options to wake up buildbonepositions now that bonemanips don't always do that)
if SERVER then

	util.AddNetworkString("AdvBone_ResetBoneChangeTime_SendToCl")

	AdvBone_ResetBoneChangeTime = function(ent)
		//Limit how often the server sends this to clients; i don't know of any obvious cases where this would happen a lot like AdvBone_ResetBoneChangeTimeOnChildren does from manips
		//or stop motion helper, but let's be safe here
		local time = CurTime()
		ent.AdvBone_ResetBoneChangeTime_LastSent = ent.AdvBone_ResetBoneChangeTime_LastSent or 0
		if time > ent.AdvBone_ResetBoneChangeTime_LastSent then
			ent.AdvBone_ResetBoneChangeTime_LastSent = time
			net.Start("AdvBone_ResetBoneChangeTime_SendToCl", true)
				net.WriteEntity(ent)
			net.Broadcast()
		end
	end

else

	net.Receive("AdvBone_ResetBoneChangeTime_SendToCl", function()
		local ent = net.ReadEntity()
		if IsValid(ent) then
			ent.LastBoneChangeTime = CurTime()
		end
	end)

end

//Networking for controlpanel options
if SERVER then

	//AdvBone_ToolBoneManip_SendToSv structure:
	//	Entity: Selected entity
	//	Int(9): Number of bones to edit
	//	FOR EACH ENTRY:
	//		Int(9): Bone index
	//
	//	UInt(4): Manip type index
	//	FOR BONEINFO TARGET BONE:
	//		Int(9): Target bone index
	//		Bool: Do demo fix
	//	FOR BONEINFO SCALE:
	//		Bool: Follow target bone scale
	//		Bool: Do demo fix
	//	FOR POS/ANG/SCALE MANIP:
	//		Float: New value for axis

	util.AddNetworkString("AdvBone_ToolBoneManip_SendToSv")

	//If we received a bonemanip from the client (sent by using the bonemanip controls), then apply it to the entity's bone(s) and update the NWvars
	net.Receive("AdvBone_ToolBoneManip_SendToSv", function(_, ply)
		local ent = net.ReadEntity()
		local boneids_read = {}
		for i = 1, net.ReadInt(9) do
			boneids_read[i] = net.ReadInt(9)
		end
		local which = net.ReadUInt(4)

		local val, demofix
		if which == 0 then //boneinfo target bone
			val = net.ReadInt(9)
			demofix = net.ReadBool()
		elseif which == 1 then //boneinfo scale
			val = net.ReadBool()
			demofix = net.ReadBool()
		else //pos/ang/scale axis slider
			val = net.ReadFloat()
		end

		//MsgN("received ToolBoneManip, which = ", which, ", val = ", val, ", ent = ", ent)
		//PrintTable(boneids_read)

		if IsValid(ent) and #boneids_read > 0 then
			local did_boneinfo = false
			for k, entbone in pairs (boneids_read) do
				if which == 0 then //boneinfo target bone
					if ent.AdvBone_BoneInfo and ent.AdvBone_BoneInfo[entbone] and val != -2 then
						if val != -1 and IsValid(ent:GetParent()) then
							if ent:GetParent().AttachedEntity then
								ent.AdvBone_BoneInfo[entbone].parent = ent:GetParent().AttachedEntity:GetBoneName(val)
							else
								ent.AdvBone_BoneInfo[entbone].parent = ent:GetParent():GetBoneName(val)
							end
						else
							ent.AdvBone_BoneInfo[entbone].parent = ""
						end
						did_boneinfo = true
					end
				elseif which == 1 then //boneinfo scale
					if ent.AdvBone_BoneInfo and ent.AdvBone_BoneInfo[entbone] then
						ent.AdvBone_BoneInfo[entbone].scale = val
						did_boneinfo = true
					end
				elseif which == 2 or which == 3 or which == 4 then //pos axis slider
					local pos = ent:GetManipulateBonePosition(entbone)
					pos[which-1] = val
					ent:ManipulateBonePosition(entbone, pos)
				elseif which == 5 or which == 6 or which == 7 then //ang axis slider
					local ang = ent:GetManipulateBoneAngles(entbone)
					ang[which-4] = val
					ent:ManipulateBoneAngles(entbone, ang)
				elseif which == 8 or which == 9 or which == 10 then //scale axis slider
					local scale = ent:GetManipulateBoneScale(entbone)
					scale[which-7] = val
					ent:ManipulateBoneScale(entbone, scale)
				else //scale xyz slider
					ent:ManipulateBoneScale(entbone, Vector(val, val, val))
				end
			end

			if did_boneinfo then
				//Tell all the other clients that they need to update their BoneInfo tables to receive the changes (the original client already has the changes applied)
				local filter = RecipientFilter()
				filter:AddAllPlayers()
				if !demofix then filter:RemovePlayer(ply) end //Fix for demo recording - demos don't record boneinfo changes made by the tool, but they DO record network activity, so if ply was recording a demo, then send them a table update too
				net.Start("AdvBone_EntBoneInfoTableUpdate_SendToCl")
					net.WriteEntity(ent)
				net.Send(filter)

				//We've modified the boneinfo table, so it's not default - save it on unmerge
				if IsValid(ent:GetParent()) then
					ent.AdvBone_BoneInfo_IsDefault = false
				end
			end

			//Wake up BuildBonePositions
			AdvBone_ResetBoneChangeTime(ent)
			AdvBone_ResetBoneChangeTimeOnChildren(ent, true)
		end
	end)



	//AdvBone_CPanelInput_SendToSv structure:
	//	Entity: Target entity
	//	UInt(4): Input index

	util.AddNetworkString("AdvBone_CPanelInput_SendToSv")

	//Respond to misc inputs from the control panel
	net.Receive("AdvBone_CPanelInput_SendToSv", function(_, ply)
		if !IsValid(ply) then return end

		local ent = net.ReadEntity()
		if !IsValid(ent) then return end //TODO: this is bad, rework this func so we can still read all the values without needing ent to be valid

		//Fake traceresult table used for CanTool and tool click functions, from an imaginary trace starting and ending at the origin of the entity
		local tr = {
			AllSolid = true,
			Entity = ent,
			Fraction = 0,
			FractionLeftSolid = 0,
			Hit = true,
			HitBox = 0,
			HitBoxBone = 0,
			HitGroup = 0,
			HitNoDraw = false,
			HitNonWorld = true,
			HitNormal = Vector(0,0,0),
			HitPos = ent:GetPos(),
			HitSky = false,
			HitTexture = "**studio**",
			HitWorld = false,
			MatType	= MAT_DEFAULT,
			Normal = Vector(0,0,1),
			PhysicsBone = 0,
			StartPos = ent:GetPos(),
			StartSolid = true,
			SurfaceProps = 0,
		}

		local input = net.ReadUInt(4)
		//if input then return end

		if input == 0 then //unmerge

			if ent:GetClass() != "ent_advbonemerge" and ent:GetClass() != "prop_animated" then return end

			//Send a notification to the player saying whether or not we managed to unmerge the entity
			if ent:Unmerge(ply) then
				ply:SendLua("GAMEMODE:AddNotify('#undone_AdvBonemerge', NOTIFY_UNDO, 2)")
				ply:SendLua("surface.PlaySound('buttons/button15.wav')")
			else
				ply:SendLua("GAMEMODE:AddNotify('Cannot unmerge this entity', NOTIFY_ERROR, 5)")
				ply:SendLua("surface.PlaySound('buttons/button11.wav')")
			end

		elseif input == 1 then //disable animation

			if ent:GetClass() != "prop_animated" or !IsValid(ent:GetParent()) then return end

			ent.IsAdvBonemerged = nil //merged animprops save this value to tell them not to create a physobj when pasted; we don't want this since it'll return true if we unmerge it after this, leading to an unparented animprop with no physics
			local newent = CreateAdvBonemergeEntity(ent, ent:GetParent(), ply, true, false, false)
			if !IsValid(newent) then return end

			//Apply the adv bonemerge constraint
			local const = constraint.AdvBoneMerge(ent:GetParent(), newent, ply)

			//Add an undo entry
			undo.Create("AdvBonemerge")
				undo.AddEntity(const)  //the constraint entity will unmerge newent upon being removed
				undo.SetPlayer(ply)
			undo.Finish("Adv. Bonemerge (" .. tostring(newent:GetModel()) .. ")")

			//Tell the client to add the new model to the controlpanel's model list (the old one will be automatically removed) - do this on a timer so the entity isn't still null on the client's end
			timer.Simple(0.1, function()
				if !IsValid(newent) then return end
				net.Start("AdvBone_NewModelToCPanel_SendToCl")
					net.WriteEntity(newent)
					net.WriteString(newent:GetNWString("AdvBone_CustomName", ""))
				net.Send(ply)
			end)
		
			ent:Remove()

		elseif input == 2 then //face poser select

			if !GetConVar("toolmode_allow_faceposer"):GetBool() or !gamemode.Call("CanTool", ply, tr, "faceposer") then return end

			local tool = ply:GetTool("faceposer")
			if !istable(tool) then return end

			ply:ConCommand("gmod_tool faceposer")
			tool:RightClick(tr)

		elseif input == 3 then //eye poser left click (click on point to look at)

			if !GetConVar("toolmode_allow_eyeposer"):GetBool() or !gamemode.Call("CanTool", ply, tr, "eyeposer") then return end

			local tool = ply:GetTool("eyeposer")
			if !istable(tool) then return end

			//Don't try to select the entity with the eye poser if the eye poser already has something else selected, because that would just pose their eyes instead.
			//TODO: this has no feedback for the player, it just silently fails, figure out a better way to do this
			if !tool.SelectedEntity then
				ply:ConCommand("gmod_tool eyeposer")
				tool:LeftClick(tr)
			end

		elseif input == 4 then //eye poser right click (edit with cpanel)

			if !GetConVar("toolmode_allow_eyeposer"):GetBool() or !gamemode.Call("CanTool", ply, tr, "eyeposer") then return end

			local tool = ply:GetTool("eyeposer")
			if !istable(tool) then return end

			ply:ConCommand("gmod_tool eyeposer")
			tool:RightClick(tr)

		elseif input == 5 then //eye poser look at player

			if !GetConVar("toolmode_allow_eyeposer"):GetBool() or !gamemode.Call("CanTool", ply, tr, "eyeposer") then return end

			local tool = ply:GetTool("eyeposer")
			if !istable(tool) then return end

			tool:MakeLookAtMe(tr)

		elseif input == 6 then //set bodygroup

			local body = net.ReadUInt(8)
			local id = net.ReadUInt(8)

			if !gamemode.Call("CanProperty", ply, "bodygroups", ent) then return end

			ent:SetBodygroup(body, id)

		elseif input == 7 then //set skin

			local skinid = net.ReadUInt(8)

			if !gamemode.Call("CanProperty", ply, "skin", ent) then return end

			ent:SetSkin(skinid)

		elseif input == 8 then //disable beard flexifier

			if !IsValid(ent:GetParent()) then return end

			ent:SetNWBool("DisableBeardFlexifier", !ent:GetNWBool("DisableBeardFlexifier"))

		elseif input == 9 or input == 10 then //finger poser left/right

			if !GetConVar("toolmode_allow_finger"):GetBool() or !gamemode.Call("CanTool", ply, tr, "finger") then return end

			local tool = ply:GetTool("finger")
			if !istable(tool) then return end

			local LeftHandMatrix, RightHandMatrix = tool:GetHandPositions(ent)
			if input == 9 then
				tr.HitPos = LeftHandMatrix:GetTranslation()
			else
				tr.HitPos = RightHandMatrix:GetTranslation()
			end

			ply:ConCommand("gmod_tool finger")
			tool:RightClick(tr)

		elseif input == 11 then //set custom name

			local str = net.ReadString()

			if str != "" then
				ent:SetNWString("AdvBone_CustomName", str)
				duplicator.StoreEntityModifier(ent, "AdvBone_CustomName", {name = str})
			else
				ent:SetNWString("AdvBone_CustomName", nil)
				duplicator.ClearEntityModifier(ent, "AdvBone_CustomName")
			end

		end
	end)

	duplicator.RegisterEntityModifier("AdvBone_CustomName", function(ply, ent, data)
		if IsValid(ent) then
			ent:SetNWString("AdvBone_CustomName", data.name)
			duplicator.StoreEntityModifier(ent, "AdvBone_CustomName", data) //is this necessary?
		end
	end)



	//AdvBone_BoneManipPaste_SendToSv structure:
	//	Entity: Entity to modify
	//
	//	Bool: Do demo fix
	//
	//	Int(9): Number of bonemanip entries
	//	FOR EACH ENTRY:
	//		Int(9): Bone index for this entry
	//
	//		Bool: Do target bone name?
	//		IF TRUE:
	//			String: Target bone name
	//		Bool: Follow target bone scale
	//
	//		Bool: Do pos manip?
	//		IF TRUE:
	//			Float: Pos X
	//			Float: Pos Y
	//			Float: Pos Z
	//		Bool: Do ang manip?
	//		IF TRUE:
	//			Float: Ang P
	//			Float: Ang Y
	//			Float: Ang R
	//		Bool: Do scale manip?
	//		IF TRUE:
	//			Float: Scale X
	//			Float: Scale Y
	//			Float: Scale Z

	util.AddNetworkString("AdvBone_BoneManipPaste_SendToSv")

	//If we received a bonemanip table from the client (for multiple bones, sent by using the Paste Bone Settings option in the model list), then apply it to the entity
	net.Receive("AdvBone_BoneManipPaste_SendToSv", function(_, ply)
		local ent = net.ReadEntity()

		local demofix = net.ReadBool()

		local count = net.ReadInt(9)
		for i = 1, count do
			local id = net.ReadInt(9)

			local targetbone
			if net.ReadBool() then
				targetbone = net.ReadString()
			end
			local scaletarget = net.ReadBool()

			local newpos, newang, newscl
			if net.ReadBool() then
				newpos = Vector(net.ReadFloat(), net.ReadFloat(), net.ReadFloat())
			end
			if net.ReadBool() then
				newang = Angle(net.ReadFloat(), net.ReadFloat(), net.ReadFloat())
			end
			if net.ReadBool() then
				newscl = Vector(net.ReadFloat(), net.ReadFloat(), net.ReadFloat())
			end

			if IsValid(ent) then
				if ent.AdvBone_BoneInfo and ent.AdvBone_BoneInfo[id] then
					if targetbone == nil then targetbone = ent.AdvBone_BoneInfo[id].parent end
					ent.AdvBone_BoneInfo[id] = {
						parent = targetbone,
						scale = scaletarget,
					}
					//Wake up BuildBonePositions
					AdvBone_ResetBoneChangeTime(ent)
					AdvBone_ResetBoneChangeTimeOnChildren(ent, true)
				end

				if newpos then ent:ManipulateBonePosition(id,newpos) end
				if newang then ent:ManipulateBoneAngles(id,newang) end
				if newscl then ent:ManipulateBoneScale(id,newscl) end
			end
		end

		if IsValid(ent) and ent.AdvBone_BoneInfo then
			//Tell all the other clients that they need to update their BoneInfo tables to receive the changes (the original client already has the changes applied)
			local filter = RecipientFilter()
			filter:AddAllPlayers()
			if !demofix then filter:RemovePlayer(ply) end //Fix for demo recording - demos don't record boneinfo changes made by the tool, but they DO record network activity, so if ply was recording a demo, then send them a table update too
			net.Start("AdvBone_EntBoneInfoTableUpdate_SendToCl")
				net.WriteEntity(ent)
			net.Send(filter)

			//We've modified the boneinfo table, so it's not default - save it on unmerge
			if IsValid(ent:GetParent()) then
				ent.AdvBone_BoneInfo_IsDefault = false
			end
		end
	end)



	util.AddNetworkString("AdvBone_EntBoneInfoTableUpdate_SendToCl")

end

if CLIENT then

	//If we received a message from the server telling us an ent's BoneInfo table is out of date, then change its AdvBone_BoneInfo_Received value so its Think function requests a new one
	net.Receive("AdvBone_EntBoneInfoTableUpdate_SendToCl", function()
		local ent = net.ReadEntity()
		if !IsValid(ent) or (ent:GetClass() != "ent_advbonemerge" and ent:GetClass() != "prop_animated") then return end

		ent.AdvBone_BoneInfo_Received = false
	end)




	local function SendBoneManipToServer(which)

		local panel = controlpanel.Get("advbonemerge")
		if !panel or !panel.modellist or !which then return end

		local ent = panel.modellist.selectedent
		local boneids = panel.bonelist:GetSelected()

		local whichtab = {
			[panel.targetbonelist] = 0,
			[panel.checkbox_scaletarget] = 1,
			[panel.slider_trans_x] = 2,
			[panel.slider_trans_y] = 3,
			[panel.slider_trans_z] = 4,
			[panel.slider_rot_p] = 5,
			[panel.slider_rot_y] = 6,
			[panel.slider_rot_r] = 7,
			[panel.slider_scale_x] = 8,
			[panel.slider_scale_y] = 9,
			[panel.slider_scale_z] = 10,
			[panel.slider_scale_xyz] = 11
		}
		if whichtab[which] == nil then return end
		//MsgN("SendBoneManipToServer: which = ", whichtab[which], "; ", panel.UpdatingBoneManipOptions, " ", #boneids == 0, " ", !IsValid(ent))

		if panel.UpdatingBoneManipOptions or #boneids == 0 or !IsValid(ent) then return end

		//Send all of the information to the server so the duplicator can pick it up
		net.Start("AdvBone_ToolBoneManip_SendToSv")
			net.WriteEntity(ent)
			net.WriteInt(#boneids, 9)
			for k, line in pairs (boneids) do
				net.WriteInt(line.id, 9)
			end
			net.WriteUInt(whichtab[which], 4)

			if which == panel.targetbonelist then
				local newtargetbone = panel.targetbonelist.selectedtargetbone
				//First, apply the new BoneInfo clientside
				if ent.AdvBone_BoneInfo and newtargetbone != -2 then
					for k, line in pairs (boneids) do
						if ent.AdvBone_BoneInfo[line.id] then
							if newtargetbone != -1 and IsValid(ent:GetParent()) then
								if ent:GetParent().AttachedEntity then
									ent.AdvBone_BoneInfo[line.id].parent = ent:GetParent().AttachedEntity:GetBoneName(newtargetbone)
								else
									ent.AdvBone_BoneInfo[line.id].parent = ent:GetParent():GetBoneName(newtargetbone)
								end
							else
								ent.AdvBone_BoneInfo[line.id].parent = ""
							end
						end
					end
				end
				//Then send the new value to the server
				net.WriteInt(newtargetbone, 9)
				net.WriteBool(engine.IsRecordingDemo())
			elseif which == panel.checkbox_scaletarget then
				local newscaletarget = panel.checkbox_scaletarget:GetChecked()
				//First, apply the new BoneInfo clientside
				if ent.AdvBone_BoneInfo then
					for k, line in pairs (boneids) do
						if ent.AdvBone_BoneInfo[line.id] then
							ent.AdvBone_BoneInfo[line.id].scale = newscaletarget
						end
					end
				end
				//Then send the new value to the server
				net.WriteBool(newscaletarget)
				net.WriteBool(engine.IsRecordingDemo())
			else
				//The rest are all bonemanip sliders, just send the new value to the server
				net.WriteFloat(which:GetValue())
			end
		net.SendToServer()

	end



	local function SendBoneManipPasteToServer(modelent, tab)

		if !tab then return end

		local panel = controlpanel.Get("advbonemerge")
		if !panel or !panel.modellist then return end

		local serverinfo = {}
		local parent = modelent:GetParent()
		local pastecount = 0

		for k, entry in pairs (tab) do
			local id = modelent:LookupBone(entry.bonename)
			if entry.bonename == -1 and modelent.AdvBone_BoneInfo and modelent:GetBoneName(0) != "static_prop" then id = -1 end //don't apply bone -1 to ents that don't have origin manips

			if id then
				//Compile information to be sent to the server for this bone
				local serverentry = table.Copy(entry)
				serverentry.id = id
				serverentry.bonename = nil

				//Only send manips to the server if the value has changed, otherwise there's no point
				//Apply the manips clientside too, so that UpdateBoneManipOptions can get their values immediately
				if serverentry.trans != modelent:GetManipulateBonePosition(id) then
					modelent:ManipulateBonePosition(id, serverentry.trans)
				else
					serverentry.trans = nil
				end
				if serverentry.rot != modelent:GetManipulateBoneAngles(id) then
					modelent:ManipulateBoneAngles(id, serverentry.rot)
				else
					serverentry.rot = nil
				end
				if serverentry.scale != modelent:GetManipulateBoneScale(id) then
					modelent:ManipulateBoneScale(id, serverentry.scale)
				else
					serverentry.scale = nil
				end
				
				local targetbone_changed
				local scaletarget_changed
				if modelent.AdvBone_BoneInfo and modelent.AdvBone_BoneInfo[id] then
					//Same thing with targetbone, don't send it to the server if the value hasn't changed
					if modelent.AdvBone_BoneInfo[id].parent != entry.targetbone then
						targetbone_changed = true
					end
					//And scaletarget - this one's a bit different since it'd be silly to network
					//an "are we sending this" bool for a value that's already a bool, so we always
					//send it as long as anything on this bone has changed
					if modelent.AdvBone_BoneInfo[id].scale != entry.scaletarget then
						scaletarget_changed = true
					end
					//Also apply the new BoneInfo clientside
					modelent.AdvBone_BoneInfo[id] = {
						parent = entry.targetbone,
						scale = entry.scaletarget,
					}
				end
				if !targetbone_changed then
					serverentry.targetbone = nil
				end

				//Update visuals of list entries to show their new status
				if modelent == panel.modellist.selectedent then
					local targetboneid = -1
					if entry.targetbone != "" and IsValid(parent) then targetboneid = parent:LookupBone(entry.targetbone) end
					panel.bonelist.Bones[id].HasTargetBone = targetboneid != -1
				end

				//If nothing has changed for this bone, don't bother sending it to the server
				if !(!scaletarget_changed and !serverentry.targetbone and !serverentry.trans and !serverentry.rot and !serverentry.scale) then
					table.insert(serverinfo, serverentry)
				end
				//Still keep a count of the number of bones the paste applied to, even if nothing changed
				pastecount = pastecount + 1
			end
		end

		--[[MsgN("client info:")
		PrintTable(tab)
		MsgN("server info:")
		PrintTable(serverinfo)]]

		if table.Count(serverinfo) > 0 then //if none of the bones match then this will still be empty
			//Then, send all of the information to the server so the duplicator can pick it up	
			net.Start("AdvBone_BoneManipPaste_SendToSv")
				net.WriteEntity(modelent)

				net.WriteBool(engine.IsRecordingDemo())

				net.WriteInt(table.Count(serverinfo), 9)
				for _, entry in pairs (serverinfo) do
					net.WriteInt(entry.id, 9)

					net.WriteBool(entry.targetbone)
					if entry.targetbone then
						net.WriteString(entry.targetbone)
					end
					net.WriteBool(entry.scaletarget) //no "should we send this" bool for this one since it's already just a bool
					
					net.WriteBool(entry.trans)
					if entry.trans then
						net.WriteFloat(entry.trans.x) //send 3 floats instead of a vector, because net.WriteVector clobbers precise values
						net.WriteFloat(entry.trans.y)
						net.WriteFloat(entry.trans.z)
					end
					net.WriteBool(entry.rot)
					if entry.rot then
						net.WriteFloat(entry.rot.p)
						net.WriteFloat(entry.rot.y)
						net.WriteFloat(entry.rot.r)
					end
					net.WriteBool(entry.scale)
					if entry.scale then
						net.WriteFloat(entry.scale.x)
						net.WriteFloat(entry.scale.y)
						net.WriteFloat(entry.scale.z)
					end
				end
			net.SendToServer()

			//If the paste modified the bones of the currently selected entity, then update 
			//all of the bonemanip controls to make sure they don't display out-of-date values
			if modelent == panel.modellist.selectedent then
				panel.UpdateBoneManipOptions()
			end
		end

		return pastecount

	end




	function TOOL.BuildCPanel(panel)

		//panel:AddControl("Header", {Description = "#tool.advbonemerge.help"})
		panel:AddControl("Header", {Description = "#tool.advbonemerge.desc"})




		panel.modellist = vgui.Create("DTree", panel)
		panel.modellist:SetHeight(150)
		panel:AddItem(panel.modellist)

		panel.modellist.selectedent = NULL
		panel.modellist.AllNodes = {}

		panel.modellist.AddModelNodes = function(modelent,parent)

			local allents = ents.GetAll()

			local function CreateNodes(modelent,parent)

				if !parent or parent == NULL then parent = panel.modellist end
				local ply = LocalPlayer()

				if IsValid(modelent) then

					local modelentoriginal = modelent
					if modelent.AttachedEntity then modelent = modelent.AttachedEntity end

					modelent:SetupBones()
					modelent:InvalidateBoneCache()

					local nodename = string.StripExtension( string.GetFileFromFilename(modelent:GetModel()) )
					local doparticlenamethink = false
					local function DoParticleNodeName(k)
						//ParticleControlOverhaul grip points display the name of the particle instead
						if istable(modelent.PartCtrl_ParticleEnts) then
							for k, _ in pairs (modelent.PartCtrl_ParticleEnts) do
								if k.GetParticleName and istable(k.ParticleInfo) then
									nodename = k:GetParticleName()
									//Use nice capitalized display name if possible
									local pcf = PartCtrl_GetGamePCF(k:GetPCF(), k:GetPath())
									if PartCtrl_ProcessedPCFs[pcf] and PartCtrl_ProcessedPCFs[pcf][k:GetParticleName()] then
										nodename = PartCtrl_ProcessedPCFs[pcf][k:GetParticleName()].nicename
									end
									doparticlenamethink = false
									//If the particle has multiple position cpoints, then add this cpoint's number to the nodename,
									//to tell them apart in case we merge more than one of them
									local points = 0
									local point_num = nil
									for k2, v2 in pairs (k.ParticleInfo) do
										if v2.ent != nil then
											points = points + 1
											if point_num == nil and v2.ent == modelent then
												point_num = k2
											end
										end
									end
									if points > 1 then
										nodename = nodename .. " (Pt. #" .. point_num .. ")"
									end
								else
									nodename = k.PrintName
									doparticlenamethink = false
								end
								break //grip point ents should only have a single particle effect attached
							end
						end
					end
					if modelent:GetClass() == "prop_animated" then
						nodename = nodename .. " (animated)"
					elseif modelent.PartCtrl_Grip or (modelent.GetPartCtrl_MergedGrip and modelent:GetPartCtrl_MergedGrip()) then
						doparticlenamethink = true
						DoParticleNodeName()
						//If we weren't able to get the particle name yet, then give it a placeholder name until the think func can replace it
						if doparticlenamethink then
							nodename = "(particle)"
						end
					end
					local node = parent:AddNode(nodename)

					local updatename = function() //this is a function so we can update the name after renaming or doing particlenamethink
						local cust = modelent:GetNWString("AdvBone_CustomName", "")
						if cust != "" then
							node:SetText('"' .. cust .. '"')
						else
							node:SetText(nodename)
						end
					end
					updatename()

					local nodeseticon = function(skinid) //this is a function so we can update the icon skin when using the skin utility
						if modelent.PartCtrl_Grip or (modelent.GetPartCtrl_MergedGrip and modelent:GetPartCtrl_MergedGrip()) then
							node.Icon:SetImage("icon16/fire.png")
							return
						end
						local modelicon = "spawnicons/" .. string.StripExtension(modelent:GetModel()) .. ".png"
						if file.Exists("materials/" .. modelicon, "GAME") then
							node.Icon:SetImage(modelicon)
						else
							node.Icon:SetImage("icon16/bricks.png")
						end
						//If we're using an alternate skin, then use the icon for that skin instead if possible, but use the default skin icon as a fallback otherwise
						if skinid > 0 then
							modelicon = "spawnicons/" .. string.StripExtension(modelent:GetModel()) .. "_skin" .. skinid .. ".png"
							if file.Exists("materials/" .. modelicon, "GAME") then
								node.Icon:SetImage(modelicon)
							end
						end
					end
					nodeseticon(modelent:GetSkin() or 0)

					//Left Click: Select the model and update the bone list
					node.DoClick = function()
						panel.modellist.selectedent = modelent
						panel.bonelist.PopulateBoneList() //selected ent has changed, update bone list
					end

					//Right Click: Show a dropdown menu with copy/paste and unmerge options
					node.DoRightClick = function()
						if !IsValid(modelent) then return end
						local menu = DermaMenu()

						//Unmerge
						if IsValid(modelent:GetParent()) and (modelent:GetClass() == "ent_advbonemerge" or modelent:GetClass() == "prop_animated") then
							local option = menu:AddOption('Unmerge "' .. string.Trim(node:GetText(), '"') .. '"', function()
								//Send a message to the server telling it to unmerge the entity
								net.Start("AdvBone_CPanelInput_SendToSv")
									net.WriteEntity(modelent)
									net.WriteUInt(0, 4) //input id 0
								net.SendToServer()
							end)
							option:SetImage("icon16/delete.png")

							menu:AddSpacer()
						end

						if modelent:GetClass() == "prop_animated" then

							//Edit Animated Prop
							if gamemode.Call("CanProperty", ply, "editanimprop", modelent) then
								local option = menu:AddOption("Edit Animated Prop", function()
									if (!gamemode.Call("CanProperty", ply, "editanimprop", modelent)) then return false end  //why not
									OpenAnimpropEditor(modelent)
								end)
								option:SetImage("icon16/film_edit.png")
							end

							//Disable Animation (for merged animprops only)
							if IsValid(modelent:GetParent()) then
								local option = menu:AddOption( "Disable Animated Prop", function()
									//Send a message to the server telling it to replace the entity with a regular ent_advbonemerge
									net.Start("AdvBone_CPanelInput_SendToSv")
										net.WriteEntity(modelent)
										net.WriteUInt(1, 4) //input id 1
									net.SendToServer()

									surface.PlaySound("common/wpn_select.wav")
								end )
								option:SetImage("icon16/film_delete.png")
							end

							menu:AddSpacer()

						end

						//Copy (all bones)
						local option = menu:AddOption("Copy settings from all bones", function()
							local copytab = {}

							//Fix some bones not being copied and returning invalid (i.e. playermodel weapon bones)
							modelent:SetupBones()
							modelent:InvalidateBoneCache()

							local function CopyBone(id)
								local bonename = modelent:GetBoneName(id)
								//MsgN(id, " == ", bonename)
								if id == -1 then
									bonename = -1
								end
								if bonename != "__INVALIDBONE__" then
									local entry = {}

									entry.trans = modelent:GetManipulateBonePosition(id)
									entry.rot = modelent:GetManipulateBoneAngles(id)
									entry.scale = modelent:GetManipulateBoneScale(id)
									if modelent.AdvBone_BoneInfo and modelent.AdvBone_BoneInfo[id] then
										entry.targetbone = modelent.AdvBone_BoneInfo[id].parent
										entry.scaletarget = modelent.AdvBone_BoneInfo[id].scale
									else
										entry.targetbone = ""
										entry.scaletarget = false
									end

									entry.bonename = bonename
									table.insert(copytab, entry)

									return true
								end
							end

							if modelent.AdvBone_BoneInfo and modelent:GetBoneName(0) != "static_prop" then
								CopyBone(-1)
							end

							if !GetConVar("advbonemerge_bone_hierarchyview"):GetBool() then
								for id = 0, modelent:GetBoneCount() - 1 do
									CopyBone(id)
								end
							else
								//If we're displaying bones in hierarchical order, then we should also be *copying* them in
								//hierarchical order, so that pasting the settings via selection matches the order they're 
								//listed in (like it does when they're in numerical order)
								local function CopyBonesInHierarchy(id)
									local name = modelent:GetBoneName(id)
									if CopyBone(id) then
										for _, v in ipairs (modelent:GetChildBones(id)) do
											CopyBonesInHierarchy(v)
										end
									end
								end
								for id = 0, modelent:GetBoneCount() - 1 do
									local id2 = modelent:GetBoneParent(id) 
									if id2 == nil or id2 < 0 then
										CopyBonesInHierarchy(id)
									end
								end
							end
							panel.modellist.copypasteinfo = copytab
							//PrintTable(panel.modellist.copypasteinfo)

							local name = "Copied " .. table.Count(copytab) .. " bones"
							if table.Count(copytab) == 1 then name = "Copied " .. table.Count(copytab) .. " bone" end
							GAMEMODE:AddNotify(name, NOTIFY_GENERIC, 2)
							surface.PlaySound("ambient/water/drip" .. math.random(1, 4) .. ".wav")
						end)
						option:SetImage("icon16/page_copy.png")

						//Paste (by name)
						local count = 0
						if istable(panel.modellist.copypasteinfo) then count = #panel.modellist.copypasteinfo end
						local name = "Paste " .. count .. " bone settings by name"
						if count == 1 then name = "Paste " .. count .. " bone setting by name" end
						local option = menu:AddOption(name, function()
							local count = SendBoneManipPasteToServer(modelent, panel.modellist.copypasteinfo)
							if count != nil then
								local name = "Pasted " .. count .. " bones"
								if count == 1 then name = "Pasted " .. count .. " bone" end
								GAMEMODE:AddNotify(name, NOTIFY_GENERIC, 2)
								surface.PlaySound("common/wpn_select.wav")
							end
						end)
						option:SetEnabled(count > 0)
						option:SetImage("icon16/page_paste.png")

						local spacer = menu:AddSpacer()

						//Rename
						local option = menu:AddOption("Rename", function()
							//add a dropdown option for this too, just in case double-clicking isn't obvious
							node:DoEditName()
						end)
						option:SetImage("icon16/textfield_rename.png")

						//Utilities
						local submenu, submenuoption = menu:AddSubMenu("Utilities")
						submenuoption:SetImage("icon16/folder.png")
						local utilitiesnotempty = false

							//Fake traceresult table used for CanTool, from an imaginary trace starting and ending at the origin of the entity
							local tr = {
								AllSolid = true,
								Entity = modelent,
								Fraction = 0,
								FractionLeftSolid = 0,
								Hit = true,
								HitBox = 0,
								HitBoxBone = 0,
								HitGroup = 0,
								HitNoDraw = false,
								HitNonWorld = true,
								HitNormal = Vector(0,0,0),
								HitPos = modelent:GetPos(),
								HitSky = false,
								HitTexture = "**studio**",
								HitWorld = false,
								MatType	= MAT_DEFAULT,
								Normal = Vector(0,0,1),
								PhysicsBone = 0,
								StartPos = modelent:GetPos(),
								StartSolid = true,
								SurfaceProps = 0,
							}

							//Face Poser utility
							if modelent:GetFlexNum() > 0 and GetConVar("toolmode_allow_faceposer"):GetBool() and gamemode.Call("CanTool", ply, tr, "faceposer") then
								local option = submenu:AddOption("Face Poser: Select", function()
									net.Start("AdvBone_CPanelInput_SendToSv")
										net.WriteEntity(modelent)
										net.WriteUInt(2, 4) //input id 2
									net.SendToServer()

									surface.PlaySound("common/wpn_select.wav")
								end)
								option:SetImage("icon16/emoticon_tongue.png")
								utilitiesnotempty = true
							end

							//Disable beard flexifier
							if BeardFlexifier and modelent:GetFlexNum() > 0 and IsValid(modelent:GetParent()) then
								local opt = submenu:AddOption("Auto match face pose (Cosmetic Face Poser Fix)")
								opt:SetChecked(!modelent:GetNWBool("DisableBeardFlexifier"))
								opt:SetIsCheckable(true)
								opt.OnChecked = function(s, checked)
									net.Start("AdvBone_CPanelInput_SendToSv")
										net.WriteEntity(modelent)
										net.WriteUInt(8, 4) //input id 8
									net.SendToServer()
								end
								//opt:SetImage("icon16/emoticon_tongue.png")
								utilitiesnotempty = true
							end

							//only create a spacer here if we've made options above this, just in case some goofy hypothetical model has eye posing but not face posing
							if utilitiesnotempty then
								submenu:AddSpacer()
							end

							//Eye Poser utilities
							local eyeattachment = modelent:LookupAttachment("eyes")
							if eyeattachment != 0 and GetConVar("toolmode_allow_eyeposer"):GetBool() and gamemode.Call("CanTool", ply, tr, "eyeposer") then
								local option = submenu:AddOption("Eye Poser: Left Click (aim with tool)", function()
									net.Start("AdvBone_CPanelInput_SendToSv")
										net.WriteEntity(modelent)
										net.WriteUInt(3, 4) //input id 3
									net.SendToServer()

									surface.PlaySound("common/wpn_select.wav")
								end)
								option:SetImage("icon16/eye.png")

								local option = submenu:AddOption("Eye Poser: Right Click (edit with control panel)", function()
									net.Start("AdvBone_CPanelInput_SendToSv")
										net.WriteEntity(modelent)
										net.WriteUInt(4, 4) //input id 4
									net.SendToServer()

									surface.PlaySound("common/wpn_select.wav")
								end)
								option:SetImage("icon16/eye.png")

								local option = submenu:AddOption("Eye Poser: Look at you", function()
									net.Start("AdvBone_CPanelInput_SendToSv")
										net.WriteEntity(modelent)
										net.WriteUInt(5, 4) //input id 5
									net.SendToServer()

									surface.PlaySound("common/wpn_select.wav")
								end)
								option:SetImage("icon16/eye.png")
								//option:SetIsCheckable(true) //let player right click on this one without closing the menu //doesn't work
								utilitiesnotempty = true
							end

							//only create a spacer here if we've made options above this
							if utilitiesnotempty then
								submenu:AddSpacer()
							end

							//Finger Poser utilities
							if GetConVar("toolmode_allow_finger"):GetBool() and gamemode.Call("CanTool", ply, tr, "finger") then
								local tool = ply:GetTool("finger")
								if istable(tool) and tool.GetHandPositions then
									local LeftHandMatrix, RightHandMatrix = tool:GetHandPositions(modelent)
									if LeftHandMatrix then
										local option = submenu:AddOption("Finger Poser: Select left hand", function()
											net.Start("AdvBone_CPanelInput_SendToSv")
												net.WriteEntity(modelent)
												net.WriteUInt(9, 4) //input id 9
											net.SendToServer()
		
											surface.PlaySound("common/wpn_select.wav")
										end)
										option:SetImage("icon16/arrow_turn_left.png")

										local option = submenu:AddOption("Finger Poser: Select right hand", function()
											net.Start("AdvBone_CPanelInput_SendToSv")
												net.WriteEntity(modelent)
												net.WriteUInt(10, 4) //input id 10
											net.SendToServer()
		
											surface.PlaySound("common/wpn_select.wav")
										end)
										option:SetImage("icon16/arrow_turn_right.png")
										utilitiesnotempty = true
									end
								end
							end

							//only create a spacer here if we've made options above this
							if utilitiesnotempty then
								submenu:AddSpacer()
							end

							//Bodygroup utilities - we want this to be as close to the bodygroup property as possible, so most of this code is copied from there
							local options = modelent:GetBodyGroups()
							local hasbodygroups = false
							if options then
								for k, v in pairs(options) do
									if v.num > 1 then
										hasbodygroups = true
									end
								end
							end
							if hasbodygroups and gamemode.Call("CanProperty", ply, "bodygroups", modelent) then
								local bodygroup_submenu, bodygroup_submenuoption = submenu:AddSubMenu("#bodygroups")
								bodygroup_submenuoption:SetImage("icon16/link_edit.png")
								for k, v in pairs(options) do
									if v.num <= 1 then continue end

									//If there's only 2 options, add it as a checkbox instead of a submenu
									if v.num == 2 then
										local current = modelent:GetBodygroup(v.id)
										local opposite = 1
										if current == opposite then opposite = 0 end

										local opt = bodygroup_submenu:AddOption(v.name)
										opt:SetChecked(current == 1)
										opt:SetIsCheckable(true)
										opt.OnChecked = function(s, checked)
											net.Start("AdvBone_CPanelInput_SendToSv")
												net.WriteEntity(modelent)
												net.WriteUInt(6, 4) //input id 6
												//extra uints for bodygroup info
												net.WriteUInt(v.id, 8)
												net.WriteUInt(checked and 1 or 0, 8)
											net.SendToServer()
										end
									//More than 2 options we add our own submenu
									else
										local groups = bodygroup_submenu:AddSubMenu(v.name)

										for i=1, v.num do
											local modelname = "model #" .. i
											if v.submodels and v.submodels[i - 1] != "" then modelname = v.submodels[i - 1] end
											modelname = string.Trim(modelname, ".")
											modelname = string.Trim(modelname, "/")
											modelname = string.Trim(modelname, "\\")
											modelname = string.StripExtension(modelname)

											local opt = groups:AddOption(modelname)
											opt:SetRadio(true)
											opt:SetChecked(modelent:GetBodygroup( v.id ) == i - 1)
											opt:SetIsCheckable(true)
											opt.OnChecked = function(s, checked)
												if (checked) then
													net.Start("AdvBone_CPanelInput_SendToSv")
														net.WriteEntity(modelent)
														net.WriteUInt(6, 4) //input id 6
														//extra uints for bodygroup info
														net.WriteUInt(v.id, 8)
														net.WriteUInt(i - 1, 8)
													net.SendToServer()
												end
											end
										end
									end
								end
								utilitiesnotempty = true
							end

							//Skin utilities
							local skincount = modelent:SkinCount()
							if skincount and skincount > 1 and gamemode.Call("CanProperty", ply, "skin", modelent) then
								local skin_submenu, skin_submenuoption = submenu:AddSubMenu("#skin")
								skin_submenuoption:SetImage("icon16/picture_edit.png")
								for i = 0, skincount - 1 do
									local opt = skin_submenu:AddOption("Skin " .. i)
									opt:SetRadio(true)
									opt:SetChecked(modelent:GetSkin() == i)
									opt:SetIsCheckable(true)
									opt.OnChecked = function(s, checked)
										if (checked) then
											net.Start("AdvBone_CPanelInput_SendToSv")
												net.WriteEntity(modelent)
												net.WriteUInt(7, 4) //input id 7
												net.WriteUInt(i, 8) //skin id
											net.SendToServer()
											nodeseticon(i)
										end
									end
								end
								utilitiesnotempty = true
							end
						
						if !utilitiesnotempty then 
							submenuoption:Remove()
						end

						//Edit ParticleControlOverhaul fx
						if PartCtrl_EditProperty_Filter and PartCtrl_EditProperty_Filter(_, modelent, ply) then
							menu:AddSpacer()

							local option = menu:AddOption("Edit Particle Effects..")
							option:SetImage("icon16/fire.png")
							PartCtrl_EditProperty_MenuOpen(_, option, modelent)
						end

						menu:Open()
					end

					//Double Click: Set a custom name for the node
					node.DoEditName = function()
						//almost entirely pilfered from DLabelEditable, this is distressingly simple (https://github.com/Facepunch/garrysmod/blob/master/garrysmod/lua/vgui/dlabeleditable.lua)

						local TextEdit = vgui.Create("DTextEntry", node.Label)
						TextEdit:Dock(FILL)
						TextEdit:DockMargin(node.Icon.x + node.Icon:GetWide(), 0, 0, 0)
						//TextEdit:SetText(node:GetText())
						//TextEdit:SetFont(node:GetFont())
						if node:GetText() != nodename then TextEdit:SetText(string.Trim(node:GetText(), '"')) end

						//this doesn't work, node.Label is forced to the full width of the panel by node's PerformLayout func (https://github.com/Facepunch/garrysmod/blob/master/garrysmod/lua/vgui/dtree_node.lua#L290)
						//TextEdit.OnTextChanged = function()
						//	node.Label:SizeToContents()
						//end

						TextEdit.OnEnter = function()
							local text = node:OnLabelTextChanged(TextEdit:GetText()) or TextEdit:GetText()
							if (text:byte() == 35) then text = "#" .. text end -- Hack!

							//node:SetText(text)
							hook.Run("OnTextEntryLoseFocus", TextEdit)
							TextEdit:Remove()
						end

						TextEdit.OnLoseFocus = function()
							hook.Run("OnTextEntryLoseFocus", TextEdit)
							TextEdit:Remove()
						end

						TextEdit:RequestFocus()
						TextEdit:OnGetFocus() -- Because the keyboard input might not be enabled yet! (spawnmenu)
						TextEdit:SelectAllText( true )

						node._TextEdit = TextEdit
					end

					node.OnLabelTextChanged = function(node, text)
						//send new custom name to server, to be stored on the entity
						net.Start("AdvBone_CPanelInput_SendToSv")
							net.WriteEntity(modelent)
							net.WriteUInt(11, 4) //input id 11
							//extra str for the new name
							net.WriteString(text)
						net.SendToServer()
						//set custom name immediately on the client, and update the label
						if text != "" then
							modelent:SetNWString("AdvBone_CustomName", text)
						else
							modelent:SetNWString("AdvBone_CustomName", nil)
						end
						updatename()
						return node:GetText()
					end

					node.Label.DoDoubleClick = function()
						node:DoEditName()
					end

					local nodeThinkOld = node.Think or nil
					node.Think = function()
						//don't override the node's old think function
						if nodeThinkOld then nodeThinkOld(node) end

						if !IsValid(modelent) then
							//If the node's entity no longer exists, deselect and remove the node
							if panel.modellist.TopNode == node then
								panel.modellist.PopulateModelList(NULL)
							elseif panel.modellist.selectedent == modelent then
								panel.modellist.selectedent = NULL
								panel.bonelist.PopulateBoneList() //selected ent has changed, update bone list
							end
							node:Remove()
							//fix: if we delete the last child node of a node, then it'll error when it updates because it still expects to have a child,
							//so we have to remove its empty .ChildNodes panel to prevent the error (https://github.com/Facepunch/garrysmod/blob/master/garrysmod/lua/vgui/dtree_node.lua#L239)
							local parentnode = node:GetParentNode()
							if IsValid(parentnode) then
								if IsValid(parentnode.ChildNodes) then
									local tab = parentnode.ChildNodes:GetChildren()
									local k = table.KeyFromValue(tab,node)
									if tab[k] then tab[k] = nil end
									if table.Count(tab) == 0 then
										parentnode.ChildNodes:Remove()
										parentnode.ChildNodes = nil
									end
								end
							end
						elseif modelent:GetClass() == "prop_animated" and panel.modellist.TopNode != node and !IsValid(modelent:GetParent()) then
							//If the node's entity is an animated prop that's been unmerged, deselect and remove the node
							if panel.modellist.selectedent == modelent then
								panel.modellist.selectedent = NULL
								panel.bonelist.PopulateBoneList() //selected ent has changed, update bone list
							end
							node:Remove()
							//fix: if we delete the last child node of a node, then it'll error when it updates because it still expects to have a child,
							//so we have to remove its empty .ChildNodes panel to prevent the error (https://github.com/Facepunch/garrysmod/blob/master/garrysmod/lua/vgui/dtree_node.lua#L239)
							local parentnode = node:GetParentNode()
							if IsValid(parentnode) then
								if IsValid(parentnode.ChildNodes) then
									local tab = parentnode.ChildNodes:GetChildren()
									local k = table.KeyFromValue(tab,node)
									if tab[k] then tab[k] = nil end
									if table.Count(tab) == 0 then
										parentnode.ChildNodes:Remove()
										parentnode.ChildNodes = nil
									end
								end
							end
						elseif doparticlenamethink then
							//If the node's entity is a ParticleControlOverhaul grip point that hasn't networked the necessary 
							//info to the client yet, then keep trying until we have it and can set the name properly.
							DoParticleNodeName()
							if !doparticlenamethink then
								updatename()
							end
						end
					end

					if IsValid(node) then node:SetExpanded(true) end
					if parent.SetExpanded then parent:SetExpanded(true) end

					table.insert(panel.modellist.AllNodes, modelent:EntIndex(), node)
					if !panel.modellist.TopNode then panel.modellist.TopNode = node end

					node.Label.AdvBone_EntHoverData = modelent //info for on-hover check in HUDPaint; all it needs at the moment is the ent, so this doesn't need to be a table


					////If our modelent is a prop_effect, then stop using the attachedentity now and go back to the parent ent
					//local parent = modelent:GetParent()
					//if IsValid(parent) and parent.AttachedEntity and parent.AttachedEntity == modelent then modelent = parent end

					//Create nodes for all children of modelent - this shouldn't cause any infinite loops or anything since I don't think we'll get a loop of ents parented to each other
					for _, childent in pairs (allents) do
						if childent:GetParent() == modelentoriginal and (childent:GetClass() == "ent_advbonemerge" or (childent:GetClass() == "prop_animated" and !childent.IsPuppeteer)) then
							CreateNodes(childent, node)
						end
					end

				end

			end

			CreateNodes(modelent, parent)

		end

		panel.modellist.PopulateModelList = function(ent)

			//Remove all of the nodes from the modellist
			local node = panel.modellist.TopNode		//i don't like this method, but it's the only reliable one i've found. since we're only removing the top node, does
			if IsValid(node) then node:Remove() end		//that mean that the child nodes still exist? unless panels automatically remove their children upon being removed
									//themselves, or there's some automatic garbage collection for orphaned panels which i haven't heard anything about.
			panel.modellist.TopNode = nil
			panel.modellist.AllNodes = {}

			//Deselect the currently selected model - remove its bones from the bone list since it's not selected any more
			panel.modellist.selectedent = NULL
			panel.bonelist.PopulateBoneList() //selected ent has changed, update bone list

			if IsValid(ent) then
				panel.modellist.AddModelNodes(ent, panel.modellist)

				panel.bonelist:SetHeight(300)
			else
				//Add a placeholder node - the DTree will break and become unusable if we empty it out and don't immediately add more nodes to it in the same function
				panel.modellist.AllNodes.message = panel.modellist:AddNode("(select an object)")
				panel.modellist.AllNodes.message.Icon:SetImage("gui/info.png")
				panel.modellist.TopNode = panel.modellist.AllNodes.message

				panel.bonelist:SetHeight(0)
			end

		end




		panel.bonelist = panel:AddControl("ListBox", { //note: for reference, this is actually a DListView, not a DListBox
			Label = "Bone", 
			Height = 300,
		})

		local cv_linkicons = GetConVar("advbonemerge_bone_linkicons")

		panel.bonelist.Bones = {}
		panel.bonelist:SetMultiSelect(true)
		panel.bonelist.PopulateBoneList = function()

			local ent = panel.modellist.selectedent

			panel.bonelist:Clear()
			panel.bonelist:ClearSelection() //TODO: is this unnecessary?

			if IsValid(ent) and ent:GetBoneCount() and ent:GetBoneCount() > 0 then
				ent:SetupBones()
				ent:InvalidateBoneCache()

				panel.bonelist.Bones = {}
				local parent = ent:GetParent()

				local function AddBone(name, id)
					local line = panel.bonelist:AddLine(name)
					panel.bonelist.Bones[id] = line
					line.id = id
					line.AdvBone_BoneHoverData = { //info for on-hover check in HUDPaint
						id = id,
						ent = ent
					}
					line:SetTooltip(string.TrimLeft(name))
					line:SetTooltipDelay(0)

					local selectedtargetbone = -1
					if ent.AdvBone_BoneInfo and ent.AdvBone_BoneInfo[id] then
						local targetbonestr = ent.AdvBone_BoneInfo[id].parent
						if targetbonestr != "" and IsValid(parent) then selectedtargetbone = parent:LookupBone(targetbonestr) end
					end
					if selectedtargetbone != -1 then line.HasTargetBone = true end

					//If this bone can have a target bone, then add extra visuals to the list entry to show whether it has one
					if ent.AdvBone_BoneInfo and IsValid(ent:GetParent()) then
						line.Paint = function(self, w, h)
							derma.SkinHook("Paint", "ListViewLine", self, w, h)
							if line.HasTargetBone then
								AdvBone_BoneList_IconTick = AdvBone_BoneList_IconTick or Material("icon16/tick.png")
								icon = AdvBone_BoneList_IconTick
								surface.SetDrawColor(0,255,0,35)
							else
								AdvBone_BoneList_IconCross = AdvBone_BoneList_IconCross or Material("icon16/cross.png")
								icon = AdvBone_BoneList_IconCross
								surface.SetDrawColor(255,0,0,35)
							end
							surface.DrawRect(0, 0, w, h)
							if cv_linkicons:GetBool() then //these are mostly unnecessary because the line is already colored red/green, but could be useful for colorblindness i suppose, so gate them behind a convar
								surface.SetDrawColor(255,255,255,255)
								surface.SetMaterial(icon)
								local x = w - 16
								if panel.bonelist.VBar.Enabled then x = x - panel.bonelist.VBar:GetWide() end
								surface.DrawTexturedRect(x, (h-16)/2, 16, 16)
								surface.SetDrawColor(255,255,255,(255*0.75))
								AdvBone_BoneList_IconLink = AdvBone_BoneList_IconLink or Material("icon16/link.png")
								surface.SetMaterial(AdvBone_BoneList_IconLink)
								surface.DrawTexturedRect(x, (h-16)/2, 16, 16)
							end
						end
					end
					line:SetTooltip(string.TrimLeft(name))

					//Right Click: Show a dropdown menu with individual bone copy/paste options
					line.OnRightClick = function()
						if !IsValid(ent) then return end
						local menu = DermaMenu()

						local boneids = panel.bonelist:GetSelected()

						//Copy (from JUST the selected bone(s), not the whole model)
						local name = "Copy settings from " .. #boneids .. " selected bones"
						if #boneids == 1 then name = "Copy settings from " .. #boneids .. " selected bone" end
						local option = menu:AddOption(name, function()
							local copytab = {}

							//Fix some bones not being copied and returning invalid (i.e. playermodel weapon bones)
							ent:SetupBones()
							ent:InvalidateBoneCache()

							for k, line in pairs (boneids) do
								local entry = {}

								entry.trans = ent:GetManipulateBonePosition(line.id)
								entry.rot = ent:GetManipulateBoneAngles(line.id)
								entry.scale = ent:GetManipulateBoneScale(line.id)
								if ent.AdvBone_BoneInfo and ent.AdvBone_BoneInfo[line.id] then
									entry.targetbone = ent.AdvBone_BoneInfo[line.id].parent
									entry.scaletarget = ent.AdvBone_BoneInfo[line.id].scale
								else
									entry.targetbone = ""
									entry.scaletarget = false
								end

								local bonename = ent:GetBoneName(line.id)
								//MsgN(line.id, " == ", bonename)
								if line.id == -1 then
									bonename = -1
								end

								if bonename != "__INVALIDBONE__" then
									entry.bonename = bonename
									table.insert(copytab, entry)
								end
							end
							panel.modellist.copypasteinfo = copytab
							//PrintTable(panel.modellist.copypasteinfo)

							local name = "Copied " .. table.Count(copytab) .. " bones"
							if table.Count(copytab) == 1 then name = "Copied " .. table.Count(copytab) .. " bone" end
							GAMEMODE:AddNotify(name, NOTIFY_GENERIC, 2)
							surface.PlaySound("ambient/water/drip" .. math.random(1, 4) .. ".wav")
						end)
						option:SetImage("icon16/page_copy.png")

						//Paste (by selection, not by name)
						local count = 0
						if istable(panel.modellist.copypasteinfo) then count = #panel.modellist.copypasteinfo end
						local name = "Paste " .. count .. " bone settings to " .. #boneids ..  " selected bones"
						if count == 1 and #boneids == 1 then
							name = "Paste " .. count .. " bone setting to " .. #boneids ..  " selected bone"
						elseif count == 1 then
							name = "Paste " .. count .. " bone setting to " .. #boneids ..  " selected bones"
						elseif #boneids == 1 then
							name = "Paste " .. count .. " bone settings to " .. #boneids ..  " selected bone"
						end
						local option = menu:AddOption(name, function()
							local copy_index = 1
							local pastetab = {}

							//Fix some bones not being copied and returning invalid (i.e. playermodel weapon bones)
							ent:SetupBones()
							ent:InvalidateBoneCache()

							//How this works:
							//The intended use of this feature is to allow the user to A: copy the settings of 1 bone to 1 other bone,
							//B: copy the settings of 1 bone to multiple other bones, or C: copy the settings of a set of bones to 
							//another same-sized set (i.e. copying the settings from all the left fingers to all the right fingers). 
							//However, the way we built this works with either set being any size, so we can also, say, copy just 2 
							//bones to a big set of bones (bone 1 gets copy 1, bone 2 gets copy 2, then bone 3 gets copy 1 again, and 
							//so on), or copy a big set of bones to just a few (bone 1 gets copy 1, and so on until we run out of bones 
							//to copy to, leaving the rest of the copies unused)

							for k, line in pairs (boneids) do
								local bonename = ent:GetBoneName(line.id)
								//MsgN(line.id, " == ", bonename)
								if line.id == -1 then
									bonename = -1
								end

								local entry = table.Copy(panel.modellist.copypasteinfo[copy_index])
								entry.bonename = bonename
								table.insert(pastetab, entry)

								copy_index = copy_index + 1
								if copy_index > count then copy_index = 1 end
							end

							local count = SendBoneManipPasteToServer(ent, pastetab)
							if count != nil then
								local name = "Pasted " .. count .. " bones"
								if count == 1 then name = "Pasted " .. count .. " bone" end
								GAMEMODE:AddNotify(name, NOTIFY_GENERIC, 2)
								surface.PlaySound("common/wpn_select.wav")
							end
						end)
						option:SetEnabled(count > 0)
						option:SetImage("icon16/page_paste.png")
						
						menu:Open()
					end
				end

				//AdvBone ents should have an additional control for the model origin, unless they're a "static_prop" model and don't support it (see ent_advbonemerge think function)
				local has_origin_manip
				if ent.AdvBone_BoneInfo and ent:GetBoneName(0) != "static_prop" then
					local name = "(origin)"
					if GetConVar("advbonemerge_bone_ids"):GetBool() then name = "-1: " .. name end
					AddBone("(origin)", -1)
					has_origin_manip = true
				end

				if !GetConVar("advbonemerge_bone_hierarchyview"):GetBool() then
					for id = 0, ent:GetBoneCount() - 1 do
						local name = ent:GetBoneName(id)
						if name != "__INVALIDBONE__" then
							if GetConVar("advbonemerge_bone_ids"):GetBool() then name = id .. ": " .. name end
							AddBone(name, id)
						end
					end
				else
					local function AddBonesInHierarchy(id, lvl)
						local indent = ""
						for i = 1, lvl do
							indent = indent .. "  "
						end
						local name = ent:GetBoneName(id)
						if name != "__INVALIDBONE__" then
							if GetConVar("advbonemerge_bone_ids"):GetBool() then name = id .. ": " .. name end
							AddBone(indent .. name, id)

							for _, v in ipairs (ent:GetChildBones(id)) do
								AddBonesInHierarchy(v, lvl + 1)
							end
						end
					end
					for id = 0, ent:GetBoneCount() - 1 do
						local id2 = ent:GetBoneParent(id) 
						if id2 == nil or id2 < 0 then
							local lvl = 0
							if has_origin_manip then lvl = 1 end
							AddBonesInHierarchy(id, lvl)
						end
					end
				end

				panel.bonelist:SelectFirstItem()
				panel.UpdateBoneManipOptions()

				//indents and id numbers both completely break alphabetical sorting; this wasn't even 
				//an intended feature at all, but i'm not turning it off completely because you just 
				//know there's *someone* out there who's made it an integral part of their workflow.
				panel.bonelist:SetSortable(!GetConVar("advbonemerge_bone_hierarchyview"):GetBool() and !GetConVar("advbonemerge_bone_ids"):GetBool())
			else
				//Add a placeholder line explaining why the list is empty
				local line = panel.bonelist:AddLine("(select a model above to edit its bones)")
			end

		end

		panel.bonelist.OnRowSelected = function()
			panel.UpdateBoneManipOptions()
		end




		panel.bonemanipcontainer = vgui.Create("DForm", panel)
		panel.bonemanipcontainer.Paint = function()
			surface.SetDrawColor(Color(0,0,0,70))
    			surface.DrawRect(0, 0, panel.bonemanipcontainer:GetWide(), panel.bonemanipcontainer:GetTall())
		end
		panel.bonemanipcontainer.Header:SetTall(0)
		panel.bonemanipcontainer:DockPadding(0,0,0,10) //add extra padding to the bottom of the container, so that the bottom checkbox isn't right up against the edge
		panel:AddPanel(panel.bonemanipcontainer)

		panel.UpdatingBoneManipOptions = false
		panel.UpdateBoneManipOptions = function()
			//Don't let the options accidentally update anything while we're changing their values like this
			panel.UpdatingBoneManipOptions = true

			local ent = panel.modellist.selectedent
			local boneids = panel.bonelist:GetSelected()

			if !IsValid(ent) or #boneids == 0 then
				//hide all the bonemanip options if we're not using them
				if panel.bonemanipcontainer:GetExpanded() == true then panel.bonemanipcontainer:Toggle() end
				panel.bonemanipcontainer:GetParent():SetTall(panel.bonemanipcontainer:GetTall())
			else
				//unhide all the bonemanip options if they're hidden
				if panel.bonemanipcontainer:GetExpanded() == false then panel.bonemanipcontainer:Toggle() end

				local trans, rot, scale, trans_conflict_x, trans_conflict_y, trans_conflict_z, rot_conflict_p, rot_conflict_y, rot_conflict_r, scale_conflict_x, scale_conflict_y, scale_conflict_z
				for k, line in pairs (boneids) do					
					local this_trans = ent:GetManipulateBonePosition(line.id)
					local this_rot = ent:GetManipulateBoneAngles(line.id)
					local this_scale = ent:GetManipulateBoneScale(line.id)
					trans = trans or this_trans
					rot = rot or this_rot
					scale = scale or this_scale
					if trans.x != this_trans.x then trans_conflict_x = true end
					if trans.y != this_trans.y then trans_conflict_y = true end
					if trans.z != this_trans.z then trans_conflict_z = true end
					if rot.p != this_rot.p then rot_conflict_p = true end
					if rot.y != this_rot.y then rot_conflict_y = true end
					if rot.r != this_rot.r then rot_conflict_r = true end
					if scale.x != this_scale.x then scale_conflict_x = true end
					if scale.y != this_scale.y then scale_conflict_y = true end
					if scale.z != this_scale.z then scale_conflict_z = true end
				end

				//if the keyboard focus is on a slider's text field when we update the slider's value, then the text value won't update correctly,
				//so make sure to take the focus off of the text fields first
				panel.slider_trans_x.TextArea:KillFocus()
				panel.slider_trans_y.TextArea:KillFocus()
				panel.slider_trans_z.TextArea:KillFocus()
				panel.slider_rot_p.TextArea:KillFocus()
				panel.slider_rot_y.TextArea:KillFocus()
				panel.slider_rot_r.TextArea:KillFocus()
				panel.slider_scale_x.TextArea:KillFocus()
				panel.slider_scale_y.TextArea:KillFocus()
				panel.slider_scale_z.TextArea:KillFocus()
				panel.slider_scale_xyz.TextArea:KillFocus()

				panel.slider_trans_x:SetValue(trans.x)
				panel.slider_trans_y:SetValue(trans.y)
				panel.slider_trans_z:SetValue(trans.z)
				panel.slider_rot_p:SetValue(rot.p)
				panel.slider_rot_y:SetValue(rot.y)
				panel.slider_rot_r:SetValue(rot.r)
				panel.slider_scale_x:SetValue(scale.x)
				panel.slider_scale_y:SetValue(scale.y)
				panel.slider_scale_z:SetValue(scale.z)
				panel.slider_scale_xyz:SetValue(scale.x)  //ehh

				if !trans_conflict_x then
					//taking the focus off of the text areas isn't enough, we also need to update their text manually because vgui.GetKeyboardFocus()
					//erroneously tells them that they've still got focus and shouldn't be updating themselves
					panel.slider_trans_x.TextArea:SetText(panel.slider_trans_x.Scratch:GetTextValue())
				else
					//we've selected multiple bones with conflicting values, don't show any number until this changes
					panel.slider_trans_x.TextArea:SetText("")
				end
				if !trans_conflict_y then
					panel.slider_trans_y.TextArea:SetText(panel.slider_trans_y.Scratch:GetTextValue())
				else
					panel.slider_trans_y.TextArea:SetText("")
				end
				if !trans_conflict_z then
					panel.slider_trans_z.TextArea:SetText(panel.slider_trans_z.Scratch:GetTextValue())
				else
					panel.slider_trans_z.TextArea:SetText("")
				end

				if !rot_conflict_p then
					panel.slider_rot_p.TextArea:SetText(panel.slider_rot_p.Scratch:GetTextValue())
				else
					panel.slider_rot_p.TextArea:SetText("")
				end
				if !rot_conflict_y then
					panel.slider_rot_y.TextArea:SetText(panel.slider_rot_y.Scratch:GetTextValue())
				else
					panel.slider_rot_y.TextArea:SetText("")
				end
				if !rot_conflict_r then
					panel.slider_rot_r.TextArea:SetText(panel.slider_rot_r.Scratch:GetTextValue())
				else
					panel.slider_rot_r.TextArea:SetText("")
				end

				if !scale_conflict_x then
					panel.slider_scale_x.TextArea:SetText(panel.slider_scale_x.Scratch:GetTextValue())
				else
					panel.slider_scale_x.TextArea:SetText("")
				end
				if !scale_conflict_y then
					panel.slider_scale_y.TextArea:SetText(panel.slider_scale_y.Scratch:GetTextValue())
				else
					panel.slider_scale_y.TextArea:SetText("")
				end
				if !scale_conflict_z then
					panel.slider_scale_z.TextArea:SetText(panel.slider_scale_z.Scratch:GetTextValue())
				else
					panel.slider_scale_z.TextArea:SetText("")
				end

				//be extra strict about this one, don't show a number for xyz unless all axes have same value
				if !scale_conflict_x and !scale_conflict_y and !scale_conflict_z and scale.x == scale.y and scale.x == scale.z then
					panel.slider_scale_xyz.TextArea:SetText( panel.slider_scale_xyz.Scratch:GetTextValue() )
				else
					panel.slider_scale_xyz.TextArea:SetText("")
				end

				local check
				for k, line in pairs (boneids) do
					local this_check
					if ent.AdvBone_BoneInfo and ent.AdvBone_BoneInfo[line.id] then 
						this_check = ent.AdvBone_BoneInfo[line.id].scale
					else
						this_check = false
					end
					if check == nil then
						check = this_check
						panel.checkbox_scaletarget.conflict = nil
						panel.checkbox_scaletarget:SetChecked(check)
					elseif this_check != check then
						//we've selected multiple bones with conflicting values, change how we draw the checkbox
						panel.checkbox_scaletarget.conflict = true
						panel.checkbox_scaletarget:SetChecked(true)
						break
					end
				end

				//gray out the BoneInfo options if the ent can't use them
				if ent.AdvBone_BoneInfo and IsValid(ent:GetParent()) then
					panel.targetbonelist:SetDisabled(false)
					panel.targetbonelist:SetAlpha(255)
					panel.targetbonelist_label:SetAlpha(255)
					//panel.targetbonelist:SetTooltip("The bone on the model we're attached to that this bone should follow.\nIf none is selected, then go back to following our parent bone\n(i.e. hand goes back to following the arm bone)")
					//panel.targetbonelist:SetTooltip("Bone on the model we're attached to for this bone to follow.\nIf none selected, then go back to our parent bone\n(i.e. hand goes back to arm bone)")
					//panel.targetbonelist:SetTooltip("Bone on the model we're attached to for this bone to follow;\nif none selected, then go back to default position")
					panel.targetbonelist:SetTooltip("Bone on the model we're attached to for this bone to follow")
				else
					panel.targetbonelist:SetDisabled(true)
					panel.targetbonelist:SetAlpha(75)
					panel.targetbonelist_label:SetAlpha(75)
					panel.targetbonelist:SetTooltip("Option only available for attached models")
				end
				if ent.AdvBone_BoneInfo then
					panel.checkbox_scaletarget:SetDisabled(false)
					//panel.checkbox_scaletarget:SetTooltip("Should this bone scale with the bone it's following?\n(If target bone is set, then scale with that bone;\nif no target bone is set, then scale with our parent bone)")
					panel.checkbox_scaletarget:SetTooltip("Should this bone scale with the bone it's following?")
				else
					panel.checkbox_scaletarget:SetDisabled(true)
					panel.checkbox_scaletarget:SetTooltip("Option not available for this entity")
				end

				//gray out the scale sliders for particle grips
				local function SetSliderDisabled(slider, disable)
					if disable then
						slider:SetMouseInputEnabled(false)
						slider:SetAlpha(75)
					else
						slider:SetMouseInputEnabled(true)
						slider:SetAlpha(255)
					end
				end
				if ent.PartCtrl_Grip or (ent.GetPartCtrl_MergedGrip and ent:GetPartCtrl_MergedGrip())  then
					SetSliderDisabled(panel.slider_scale_x, true)
					SetSliderDisabled(panel.slider_scale_y, true)
					SetSliderDisabled(panel.slider_scale_z, true)
					SetSliderDisabled(panel.slider_scale_xyz, true)
					//keep the "scale with parent" check enabled, since that still makes our position manip (and our children) scale with our target bone
				else
					SetSliderDisabled(panel.slider_scale_x, false)
					SetSliderDisabled(panel.slider_scale_y, false)
					SetSliderDisabled(panel.slider_scale_z, false)
					SetSliderDisabled(panel.slider_scale_xyz, false)
				end

				panel.targetbonelist.PopulateTargetBoneList()
			end

			panel.UpdatingBoneManipOptions = false
		end


		//Target Bone
		panel.targetbonelist = vgui.Create("DComboBox", panel.targetbonelist)
		panel.targetbonelist_label = vgui.Create("DLabel", panel.targetbonelist)
			panel.targetbonelist_label:SetText("Target Bone")
			panel.targetbonelist_label:SetDark(true)
			panel.targetbonelist:SetHeight(25)
			panel.targetbonelist:Dock(TOP)
		panel.bonemanipcontainer:AddItem(panel.targetbonelist_label, panel.targetbonelist)

		panel.targetbonelist.selectedtargetbone = -2
		panel.targetbonelist.PopulateTargetBoneList = function()

			local ent = panel.modellist.selectedent
			local boneids = panel.bonelist:GetSelected()
			panel.targetbonelist:Clear()

			if !IsValid(ent) then return end
			local parent = ent:GetParent()
			if parent.AttachedEntity then parent = parent.AttachedEntity end

			if IsValid(parent) then
				parent:SetupBones()
				parent:InvalidateBoneCache()
			end

			local selectedtargetbone
			for k, line in pairs (boneids) do
				if ent.AdvBone_BoneInfo and ent.AdvBone_BoneInfo[line.id] then
					local this_targetbone = ent.AdvBone_BoneInfo[line.id].parent
					if this_targetbone != "" and IsValid(parent) then 
						this_targetbone = parent:LookupBone(this_targetbone)
					else
						this_targetbone = -1
					end
					selectedtargetbone = selectedtargetbone or this_targetbone
					if selectedtargetbone != this_targetbone then
						selectedtargetbone = -2
						break
					end
				end
			end
			selectedtargetbone = selectedtargetbone or -2
			panel.targetbonelist.selectedtargetbone = selectedtargetbone

			local nonetext = "(none)"
			if #boneids == 1 then
				for k, line in pairs (boneids) do
					if line.id == -1 or (line.id == 0 and ent:GetBoneName(0) == "static_prop") then
						if IsValid(parent) then nonetext = "(none, follow parent model's origin)" end
					else
						local parentboneid = ent:GetBoneParent(line.id)
						if parentboneid and parentboneid != -1 then
							nonetext = "(none, follow parent bone " .. ent:GetBoneName(parentboneid) .. ")"
						else
							nonetext = "(none, follow origin)"
						end
					end
					break
				end
			end
			panel.targetbonelist:AddChoice(nonetext, -1, (selectedtargetbone == -1))

			if IsValid(parent) and parent:GetBoneCount() and parent:GetBoneCount() != 0 then
				if !GetConVar("advbonemerge_bone_hierarchyview"):GetBool() then
					for id = 0, parent:GetBoneCount() - 1 do
						local name = parent:GetBoneName(id)
						if name != "__INVALIDBONE__" then
							if GetConVar("advbonemerge_bone_ids"):GetBool() then name = id .. ": " .. name end
							panel.targetbonelist:AddChoice(name, id, (selectedtargetbone == id))
						end
					end
				else
					local function AddBonesInHierarchy(id, lvl)
						local indent = ""
						for i = 1, lvl do
							indent = indent .. "  "
						end
						local name = parent:GetBoneName(id)
						if name != "__INVALIDBONE__" then
							if GetConVar("advbonemerge_bone_ids"):GetBool() then name = id .. ": " .. name end
							panel.targetbonelist:AddChoice(indent .. name, id, (selectedtargetbone == id))

							for _, v in ipairs (parent:GetChildBones(id)) do
								AddBonesInHierarchy(v, lvl + 1)
							end
						end
					end
					for id = 0, parent:GetBoneCount() - 1 do
						local id2 = parent:GetBoneParent(id) 
						if id2 == nil or id2 < 0 then
							AddBonesInHierarchy(id, 0)
						end
					end
				end
			end

		end
		panel.targetbonelist.OnSelect = function(_,_,value,data)
			panel.targetbonelist.selectedtargetbone = data
			SendBoneManipToServer(panel.targetbonelist)

			//Update visuals of list entries to show their new status
			for k, line in pairs (panel.bonelist:GetSelected()) do
				if panel.bonelist.Bones[line.id] then
					panel.bonelist.Bones[line.id].HasTargetBone = data != -1
				end
			end

			//Don't show indents in selected bone name
			panel.targetbonelist:SetText(string.TrimLeft(value))
		end
		panel.targetbonelist:SetSortItems(false)

		//Modified OpenMenu fuction to check the currently selected bone
		panel.targetbonelist.OpenMenu = function(self, pControlOpener)
			if ( pControlOpener && pControlOpener == self.TextEntry ) then
				return
			end

			-- Don't do anything if there aren't any options..
			if ( #self.Choices == 0 ) then return end

			-- If the menu still exists and hasn't been deleted
			-- then just close it and don't open a new one.
			if ( IsValid( self.Menu ) ) then
				self.Menu:Remove()
				self.Menu = nil
			end

			self.Menu = DermaMenu( false, self )

			//only this block is meaningfully changed
			local ent = panel.modellist.selectedent
			if IsValid(ent) then ent = ent:GetParent() end
			if IsValid(ent) and ent.AttachedEntity then ent = ent.AttachedEntity end
			for k, v in pairs (self.Choices) do
				local option = self.Menu:AddOption( v, function() self:ChooseOption( v, k ) end )
				if panel.targetbonelist.selectedtargetbone == self.Data[k] then option:SetChecked(true) end  //check the currently selected target bone
				
				if self.Data[k] >= 0 then //don't show for "(none)" option
					option.AdvBone_BoneHoverData = { //info for on-hover check in HUDPaint
						id = self.Data[k],
						ent = ent
					}
				end
			end

			local x, y = self:LocalToScreen( 0, self:GetTall() )

			self.Menu:SetMinimumWidth( self:GetWide() )
			self.Menu:Open( x, y, false, self )
		end


		panel.bonemanipcontainer:Help("")


		//Function overrides for sliders to unclamp them
		local function SliderValueChangedUnclamped( self, val )
			//don't clamp this
			//val = math.Clamp( tonumber( val ) || 0, self:GetMin(), self:GetMax() )

			self.Slider:SetSlideX( self.Scratch:GetFraction( val ) )

			if ( self.TextArea != vgui.GetKeyboardFocus() ) then
				self.TextArea:SetValue( self.Scratch:GetTextValue() )
			end

			self:OnValueChanged( val )
		end

		local function SliderSetValueUnclamped( self, val )
			//don't clamp this
			//val = math.Clamp( tonumber( val ) || 0, self:GetMin(), self:GetMax() )
	
			if ( self:GetValue() == val ) then return end

			self.Scratch:SetValue( val )

			self:ValueChanged( self:GetValue() )
		end


		//Translation
		local slider = panel.bonemanipcontainer:NumSlider("Move X", nil, -128, 128, 2)
		slider.ValueChanged = SliderValueChangedUnclamped
		slider.SetValue = SliderSetValueUnclamped
		slider:SetHeight(9)
		slider:SetDefaultValue(0.000)
		slider:SetDecimals(3)
		panel.slider_trans_x = slider
		slider.OnValueChanged = function() SendBoneManipToServer(panel.slider_trans_x) end

		local slider = panel.bonemanipcontainer:NumSlider("Move Y", nil, -128, 128, 2)
		slider.ValueChanged = SliderValueChangedUnclamped
		slider.SetValue = SliderSetValueUnclamped
		slider:SetHeight(9)
		slider:SetDefaultValue(0.000)
		slider:SetDecimals(3)
		panel.slider_trans_y = slider
		slider.OnValueChanged = function() SendBoneManipToServer(panel.slider_trans_y) end

		local slider = panel.bonemanipcontainer:NumSlider("Move Z", nil, -128, 128, 2)
		slider.ValueChanged = SliderValueChangedUnclamped
		slider.SetValue = SliderSetValueUnclamped
		slider:SetHeight(9)
		slider:SetDefaultValue(0.000)
		slider:SetDecimals(3)
		panel.slider_trans_z = slider
		slider.OnValueChanged = function() SendBoneManipToServer(panel.slider_trans_z) end


		panel.bonemanipcontainer:Help("")


		//Rotation
		local slider = panel.bonemanipcontainer:NumSlider("Pitch", nil, -180, 180, 2)
		slider:SetHeight(9)
		slider:SetDefaultValue(0.000)
		slider:SetDecimals(3)
		panel.slider_rot_p = slider
		slider.OnValueChanged = function() SendBoneManipToServer(panel.slider_rot_p) end

		local slider = panel.bonemanipcontainer:NumSlider("Yaw", nil, -180, 180, 2)
		slider:SetHeight(9)
		slider:SetDefaultValue(0.000)
		slider:SetDecimals(3)
		panel.slider_rot_y = slider
		slider.OnValueChanged = function() SendBoneManipToServer(panel.slider_rot_y) end

		local slider = panel.bonemanipcontainer:NumSlider("Roll", nil, -180, 180, 2)
		slider:SetHeight(9)
		slider:SetDefaultValue(0.000)
		slider:SetDecimals(3)
		panel.slider_rot_r = slider
		slider.OnValueChanged = function() SendBoneManipToServer(panel.slider_rot_r) end


		panel.bonemanipcontainer:Help("")


		//Scale
		local slider = panel.bonemanipcontainer:NumSlider("Scale X", nil, 0, 20, 2)
		slider.ValueChanged = SliderValueChangedUnclamped
		slider.SetValue = SliderSetValueUnclamped
		slider:SetHeight(9)
		slider:SetDefaultValue(1.000)
		slider:SetDecimals(3)
		panel.slider_scale_x = slider
		slider.OnValueChanged = function() SendBoneManipToServer(panel.slider_scale_x) end

		local slider = panel.bonemanipcontainer:NumSlider("Scale Y", nil, 0, 20, 2)
		slider.ValueChanged = SliderValueChangedUnclamped
		slider.SetValue = SliderSetValueUnclamped
		slider:SetHeight(9)
		slider:SetDefaultValue(1.000)
		slider:SetDecimals(3)
		panel.slider_scale_y = slider
		slider.OnValueChanged = function() SendBoneManipToServer(panel.slider_scale_y) end

		local slider = panel.bonemanipcontainer:NumSlider("Scale Z", nil, 0, 20, 2)
		slider.ValueChanged = SliderValueChangedUnclamped
		slider.SetValue = SliderSetValueUnclamped
		slider:SetHeight(9)
		slider:SetDefaultValue(1.000)
		slider:SetDecimals(3)
		panel.slider_scale_z = slider
		slider.OnValueChanged = function() SendBoneManipToServer(panel.slider_scale_z) end

		local slider = panel.bonemanipcontainer:NumSlider("Scale XYZ", nil, 0, 20, 2)
		slider.ValueChanged = SliderValueChangedUnclamped
		slider.SetValue = SliderSetValueUnclamped
		slider:SetHeight(9)
		slider:SetDefaultValue(1.000)
		slider:SetDecimals(3)
		panel.slider_scale_xyz = slider
		slider.OnValueChanged = function()
			if panel.UpdatingBoneManipOptions then return end
			local val = panel.slider_scale_xyz:GetValue()
			panel.slider_scale_x:SetValue(val)
			panel.slider_scale_y:SetValue(val)
			panel.slider_scale_z:SetValue(val)
			SendBoneManipToServer(panel.slider_scale_xyz) 
		end

		local checkbox = panel.bonemanipcontainer:CheckBox("Scale with target bone", nil)
		checkbox:SetHeight(15)
		panel.checkbox_scaletarget = checkbox
		checkbox.OnChange = function()
			checkbox.conflict = nil
			SendBoneManipToServer(panel.checkbox_scaletarget) 
		end
		local old_Paint = checkbox.Button.Paint
		function checkbox.Button:Paint(w, h)
			old_Paint(self, w, h)
			//If multiple bones are selected that have conflicting values, then 
			//draw the box with a faded-out check to show the indeterminate state
			if checkbox.conflict then
				local alpha = surface.GetAlphaMultiplier()
				surface.SetAlphaMultiplier(0.5)
				checkbox:SetChecked(false)
				old_Paint(self, w, h)
				checkbox:SetChecked(true)
				surface.SetAlphaMultiplier(alpha)
			end
		end

		panel.bonemanipcontainer:Toggle()  //bonemanip options should be hidden by default since no entity is selected




		panel:AddControl("Label", {Text = ""})



		panel:AddControl("Checkbox", {Label = "Merge matching bones by default", Command = "advbonemerge_matchnames"})
		//panel:ControlHelp("If enabled. newly attached models start off with all bones following the parent model's bones with matching names, like a normal bonemerge.")
		panel:ControlHelp("If on. newly attached models start off with all bones following the bones with matching names, like a normal bonemerge.")



		panel:AddControl("Label", {Text = ""})


		
		local function BonelistUpdateAppearance()
			//Compile a list of all currently selected bones that will persist after the update
			local tab = {}
			for k, line in pairs (panel.bonelist:GetSelected()) do
				tab[line.id] = true
			end
			//Update the bonelist, to change the order the bones are displayed in and/or update their display names
			panel.bonelist.PopulateBoneList()
			//Now restore the selected bones
			panel.bonelist:ClearSelection()
			for k, line in pairs (panel.bonelist:GetLines()) do
				if tab[line.id] then panel.bonelist:SelectItem(line) end
			end
		end

		local checkbox = panel:AddControl("Checkbox", {Label = "Display bone list as hierarchy", Command = "advbonemerge_bone_hierarchyview"})
		checkbox.OnChange = BonelistUpdateAppearance

		local checkbox = panel:AddControl("Checkbox", {Label = "Show bone ID numbers", Command = "advbonemerge_bone_ids"})
		checkbox.OnChange = BonelistUpdateAppearance

		panel:AddControl("Checkbox", {Label = "Show icons for linked/unlinked bones", Command = "advbonemerge_bone_linkicons"})
		
		panel:AddControl("Checkbox", {Label = "Draw selection halo", Command = "advbonemerge_drawhalo"})

	end

end