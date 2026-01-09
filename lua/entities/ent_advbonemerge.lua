AddCSLuaFile()

ENT.Base 			= "base_gmodentity"
ENT.PrintName			= "Advanced Bonemerge Entity"

ENT.Spawnable			= false
ENT.RenderGroup			= false //let the engine set the rendergroup by itself




function ENT:SetupDataTables()

	self:NetworkVar("Bool", 0, "PartCtrl_MergedGrip")

end




function ENT:Initialize()

	if SERVER then

		//We should already have a serverside table called self.AdvBone_BoneInfo - either the stool function or the duplicator should've given it to us when they created us.
		//Now all we have to do is send it to the client so the BuildBonePositions function can use it.
		if !self.AdvBone_BoneInfo then 
			MsgN("ERROR: Adv Bonemerged model " .. self:GetModel() .. " doesn't have a boneinfo table! Something went wrong!") 
			self:Remove() 
			return
		end

		self:SetCollisionBounds(vector_origin,vector_origin)  //if we don't change this, the duplicator will try to compensate for the "size" of merged models when pasting them, which can cause problems if we're merging big props and scaling them down
		self:SetTransmitWithParent(true)

		return

	end

	//Create a clientside advbone manips table so that it gets populated when the server sends us values
	self.AdvBone_BoneManips = self.AdvBone_BoneManips or {}

	self:AddEffects(EF_BONEMERGE) //necessary for proper shadow rendering
	self:AddEffects(EF_BONEMERGE_FASTCULL)
	self:SetLOD(0)
	self:SetupBones()
	self:InvalidateBoneCache()

	//Start off with renderbounds at least as large as our parent - this isn't perfect, but it should help prevent cases where clients can't see us at first because
	//our starting renderbounds are a tiny box at our parent's feet, and we won't draw and do BuildBonePositions to get proper bounds until the client looks at us
	if IsValid(self:GetParent()) then
		local mins1, maxs1 = self:GetRenderBounds()
		local mins2, maxs2 = self:GetParent():GetRenderBounds()
		mins1.x = math.min(mins1.x,mins2.x)
		mins1.y = math.min(mins1.y,mins2.y)
		mins1.z = math.min(mins1.z,mins2.z)
		maxs1.x = math.max(maxs1.x,maxs2.x)
		maxs1.y = math.max(maxs1.y,maxs2.y)
		maxs1.z = math.max(maxs1.z,maxs2.z)
		self:SetRenderBounds(mins1, maxs1)
	end

	//Store hitbox bounds by bone; we use these to help with renderbounds
	self.AdvBone_BoneHitBoxes = {}
	for i = 0, self:GetHitboxSetCount() - 1 do
		for j = 0, self:GetHitBoxCount(i) - 1 do
			local id = self:GetHitBoxBone(j, i)
			local min, max = self:GetHitBoxBounds(j, i)
			if self.AdvBone_BoneHitBoxes[id] then
				local min2 = self.AdvBone_BoneHitBoxes[id].min
				local max2 = self.AdvBone_BoneHitBoxes[id].max
				self.AdvBone_BoneHitBoxes[id].min = Vector(math.min(min.x,min2.x), math.min(min.y,min2.y), math.min(min.z,min2.z))
				self.AdvBone_BoneHitBoxes[id].max = Vector(math.max(max.x,max2.x), math.max(max.y,max2.y), math.max(max.z,max2.z))
			else
				self.AdvBone_BoneHitBoxes[id] = {min = min, max = max}
			end
		end
	end
	self.SavedLocalHitBoxes = {}

	self.LastBuildBonePositionsTime = 0
	self.SavedBoneMatrices = {}
	self.SavedLocalBonePositions = {}
	self.LastBoneChangeTime = CurTime()

	self:AddCallback("BuildBonePositions", self.BuildBonePositions)

end

if CLIENT then

	CreateClientConVar("cl_advbone_debug_sleep", 0, false, false, "If 1, show sleep status of ent_advbonemerge's BuildBonePositions function (red = asleep, green = awake)", 0, 1)
	local cv_debug_sleep = GetConVar("cl_advbone_debug_sleep")

	function ENT:BuildBonePositions(bonecount)
		if !IsValid(self) then return end
		self.BuildBonePositions_HasRun = true //Newly connected players will add this callback, but then wipe it; this tells the think func that it actually went through
		if !self.AdvBone_BoneInfo then return end

		local parent = self:GetParent()
		if !IsValid(parent) then return end
		if parent.AttachedEntity then parent = parent.AttachedEntity end
		parent:SetLOD(0)

		//This function is expensive, so make sure we aren't running it more often than we need to
		local curtime = CurTime()
		local skip = false
		if self.LastBuildBonePositionsTime >= curtime then
			//If we've already run this function this frame (i.e. entity is getting drawn more than once) then skip
			skip = true
		else
			self.LastBuildBonePositionsTime = curtime

			//If our bones haven't changed position in a while, then fall asleep and skip until one of our parent's bones moves,
			//or until we/our parent get bonemanipped (see function overrides at bottom of this page)
			//This check isn't the cheapest, but it's still a whole lot better than updating all our bones.
			if self.LastBoneChangeTime + (FrameTime() * 10) < curtime then
				if parent.AdvBone_LastParentBoneCheckTime and parent.AdvBone_LastParentBoneCheckTime >= curtime then
					//This check only needs to be performed once per frame, even if there are multiple models merged to one parent
					skip = true
				else
					//Don't bother doing this if the parent has significantly more bones than we do
					local parbonecount = parent:GetBoneCount()
					if parbonecount / 2 <= bonecount then
						local parentbones = {}
						for i = -1, parbonecount - 1 do
							local matr = parent:GetBoneMatrix(i)
							if ismatrix(matr) then
								//parentbones[i] = matr:ToTable() //this func suuucks for perf when there's a lot at once
								local t = matr:GetTranslation()
								local a = matr:GetAngles()
								parentbones[i] = {
									//These values are sloppy; bones that move procedurally from jigglebones or IK always return a slightly
									//different value each frame, so round to the nearest hammer unit
									[1] = math.Round(t.x),
									[2] = math.Round(t.y),
									[3] = math.Round(t.z),
									[4] = math.Round(a.x),
									[5] = math.Round(a.y),
									[6] = math.Round(a.z),
								}
							end
						end

						if self.SavedParentBoneMatrices then
							local ParentNoChange = true
							for k, v in pairs (self.SavedParentBoneMatrices) do
								if !parentbones[k] then
									ParentNoChange = false
								elseif ParentNoChange then
									for k2, v2 in pairs (v) do
										if ParentNoChange then
											if v2 != parentbones[k][k2] then
												ParentNoChange = false
												break
											end
										else
											break
										end
									end
								end
							end
							if !ParentNoChange then
								self.LastBoneChangeTime = curtime
								self.SavedParentBoneMatrices = nil
							else
								//MsgN(self, " ", ParentNoChange)
								skip = true
								parent.AdvBone_LastParentBoneCheckTime = curtime
							end
						else
							self.SavedParentBoneMatrices = parentbones
						end
						skip = true //TODO: saw this when looking through code, is this right? it's not here in prop_animated, is this to cover spme edge case i forgot to comment? doesn't seem to be causing problems.
					end
				end
			else
				self.SavedParentBoneMatrices = nil
			end
		end

		if cv_debug_sleep:GetBool() then
			if skip then
				self:SetColor( Color(255,0,0,255) )
			else
				self:SetColor( Color(0,255,0,255) )
			end
		end
		//If we're going to skip, then use cached bone matrices instead of computing new ones, and stop here
		if !self.HasDrawn then //fix: don't let buildbonepositions fall asleep if we spawned offscreen and haven't been seen by the client yet, otherwise it'll save bad bone positions
			self.LastBoneChangeTime = curtime
		elseif skip then
			if self.AdvBone_OriginMatrix then
				local matr = self.AdvBone_OriginMatrix
				//Move our actual model origin with the origin control
				self:SetPos(matr:GetTranslation())
				self:SetAngles(self.AdvBone_Angs[-1] or matr:GetAngles())
				//Also move our render origin - setpos alone is unreliable since the position can get reasserted if the parent moves or something like that
				self:SetRenderOrigin(matr:GetTranslation())
				self:SetRenderAngles(self.AdvBone_Angs[-1] or matr:GetAngles())
			end
			for i = 0, bonecount - 1 do
				if self.SavedBoneMatrices[i] and self:GetBoneName(i) != "__INVALIDBONE__" then
					self:SetBoneMatrix(i, self.SavedBoneMatrices[i])
				end
			end
			return
		end




		//Create a table of default bone offsets for bones to use when they're not merged to something
		if !self.AdvBone_DefaultBoneOffsets then
			//Grab the bone matrices from a clientside model instead - if we use ourselves, any bone manips we already have will be applied to the 
			//matrices, making the altered bones the new default (and then the manips will be applied again on top of them, basically "doubling" the manips)
			//(UPDATE: this entity doesn't use garrymanips any more so using a separate ent is no longer necessary. should we change this to just use this entity now?
			//it's pretty inconsequential whether we keep using this method or not, unless some other factor i'm not aware of messes up our bones or model bounds or something)
			if !self.csmodel then
				//NOTE: This used ClientsideModel before, but users reported this causing crashes with very specific models (lordaardvark dazv5 overwatch pack h ttps://mega.nz/file/1vBjUQ6D#Yj72iK7eKAkIrnbwTVp66CEgu01nQ6wLNMFXoG-fvIw). This is clearly a much deeper issue, since this same function with the same models also crashes in other contexts (like rendering spawnicons, which the model author knew about and included a workaround for), but until it's fixed a workaround like this is necessary.
				self.csmodel = ents.CreateClientProp()
				self.csmodel:SetModel(self:GetModel())
				//self.csmodel = ClientsideModel(self:GetModel(),RENDERGROUP_TRANSLUCENT)
				self.csmodel:SetPos(self:GetPos())
				self.csmodel:SetAngles(self:GetAngles())
				self.csmodel:SetMaterial("null")  //invisible texture, so players don't see the csmodel for a split second while we're generating the table
				self.csmodel:SetLOD(0)
			end
			self.csmodel:DrawModel()
			self.csmodel:SetupBones()
			self.csmodel:InvalidateBoneCache()
			if self.csmodel and self.csmodel:GetBoneMatrix(0) == nil and self.csmodel:GetBoneMatrix(bonecount - 1) == nil then return end //the csmodel might need a frame or so to start returning the matrices; on some models like office workers from Black Mesa Character Expansion (https://steamcommunity.com/sharedfiles/filedetails/?id=2082334251), this always returns nil for the root bone but still works for the others, so make sure we check more than one bone

			local defaultboneoffsets = {}
			local bonemins, bonemaxs = nil, nil
			for i = 0, bonecount - 1 do
				local newentry = {}
				local ourmatr = self.csmodel:GetBoneMatrix(i)
				local parentboneid = self.csmodel:GetBoneParent(i)
				if parentboneid and parentboneid != -1 then
					//Get the bone's offset from its parent
					local parentmatr = self.csmodel:GetBoneMatrix(parentboneid)
					if ourmatr == nil then return end  //TODO: why does this happen? does the model need to be precached or something?
					newentry.posoffset, newentry.angoffset = WorldToLocal(ourmatr:GetTranslation(), ourmatr:GetAngles(), parentmatr:GetTranslation(), parentmatr:GetAngles())
				else
					//If a bone doesn't have a parent, then get its offset from the model origin
					ourmatr = self.csmodel:GetBoneMatrix(i)
					if ourmatr != nil then
						newentry.posoffset, newentry.angoffset = WorldToLocal(ourmatr:GetTranslation(), ourmatr:GetAngles(), self.csmodel:GetPos(), self.csmodel:GetAngles())
					end
				end
				if !newentry.posoffset then
					newentry.posoffset = Vector(0,0,0)
					newentry.angoffset = Angle(0,0,0)
				end
				table.insert(defaultboneoffsets, i, newentry)

				if ourmatr then
					//Get the min and max positions of our bones ("bone bounds") for our render bounds calculation to use
					local bonepos = WorldToLocal(ourmatr:GetTranslation(), Angle(), self.csmodel:GetPos(), self.csmodel:GetAngles())
					if !bonemins and !bonemaxs then
						bonemins = Vector()
						bonemaxs = Vector()
						bonemins:Set(bonepos)
						bonemaxs:Set(bonepos)
					else
						bonemins.x = math.min(bonepos.x,bonemins.x)
						bonemins.y = math.min(bonepos.y,bonemins.y)
						bonemins.z = math.min(bonepos.z,bonemins.z)
						bonemaxs.x = math.max(bonepos.x,bonemaxs.x)
						bonemaxs.y = math.max(bonepos.y,bonemaxs.y)
						bonemaxs.z = math.max(bonepos.z,bonemaxs.z)
					end
				end
			end

			self.AdvBone_DefaultBoneOffsets = defaultboneoffsets

			if !self.AdvBone_BoneHitBoxes then //Fallback in  case we don't have any hitboxes to use for render bounds
				//Calculate the amount of extra "bloat" to put around our bones when setting our render bounds
				local modelmins, modelmaxs = self.csmodel:GetModelRenderBounds()
				//Get the largest amount of space between the bone and model bounds and use that as our bloat value - we have to use the largest size on all axes since players can 
				//rotate the model and bones however they please. If the bone bounds are somehow bigger than the model bounds, then use 0 instead.
				self.AdvBone_RenderBounds_Bloat = math.max(0, -(modelmins.x - bonemins.x), -(modelmins.y - bonemins.y), -(modelmins.z - bonemins.z), (modelmaxs.x - bonemaxs.x), (modelmaxs.y - bonemaxs.y), (modelmaxs.z - bonemaxs.z))
			end

			//We'll remove the clientside model in our Think hook, because doing it here can cause a crash
			self.csmodeltoremove = self.csmodel
			self.csmodel = nil
		end




		//self.AdvBone_BoneInfo structure:
		//self.AdvBone_BoneInfo[0] = {	     //one entry for each of our bones, by bone id
		//	parent = "bip_upperarm_l",   //target bone on our parent entity to follow - store as a string so this doesn't break if our parent entity's model changes
		//	scale = true,                //whether to use the bone's scale or just the model scale - players might want to use scale to hide parts of the parent model
		//}

		local mdlscl = math.Round(self:GetModelScale(),4) //we need to round these values or else the game won't think they're equal
		local mdlsclvec = Vector(mdlscl,mdlscl,mdlscl)

		//these will be used to set our render bounds accordingly in the clientside think function
		local highestbonescale = 0
		local bonemins, bonemaxs = nil, nil

		//scaling a matrix down can distort its angles (or remove them entirely if scaled down to 0), so whenever we scale a matrix, we'll store its non-scaled angles in here first. 
		//whenever another bone wants to follow that matrix but NOT scale with it, it'll use the stored angles from this table instead.
		self.AdvBone_Angs = {}

		//check if the bone matrices have changed at all since the last call
		local BonesHaveChanged = (self.LastBoneChangeTime == curtime) //don't bother checking this later if we already know they've changed

		for i = -1, bonecount - 1 do

			local matr = nil
			local targetboneid = parent:LookupBone(self.AdvBone_BoneInfo[i].parent)
			if targetboneid then

				//Set our bone to the matrix of its target bone on the other model

				local targetmatr = parent:GetBoneMatrix(targetboneid)
				if targetmatr then

					if parent.AdvBone_StaticPropMatrix and self.AdvBone_BoneInfo[i].parent == "static_prop" then
						//The static_prop workaround uses some nonsense with EnableMatrix/RenderMultiply to work, so the matrix we retrieve here 
						//won't have the right angles or scale. Use a stored matrix with the proper values instead.
						targetmatr:Set(parent.AdvBone_StaticPropMatrix)
					end

					matr = targetmatr

					if (self.AdvBone_BoneInfo[i].scale == false) then
						//Since we don't want to use the target bone's scale, rescale the matrix so it's back to normal
						matr:SetScale(mdlsclvec)  //we still want to inherit the overall model scale for things like npcs and animated props

						if parent.AdvBone_Angs and parent.AdvBone_Angs[targetboneid] then
							//Use our target bone's stored angles if possible
							matr:SetAngles(parent.AdvBone_Angs[targetboneid])
						end

						//If the target bone's scale is under 0.04 on any axis, then we can't scale it back up properly, so let's fix that
						//We can't just create a new matrix instead and copy over the translation and angles, since 0-scale matrices lose their angle info
						local scalevec = parent:GetManipulateBoneScale(targetboneid)
						local scalefix = false
						if scalevec.x < 0.04 then scalevec.x = 0.05 scalefix = true end
						if scalevec.y < 0.04 then scalevec.y = 0.05 scalefix = true end
						if scalevec.z < 0.04 then scalevec.z = 0.05 scalefix = true end
						if scalefix == true then parent:ManipulateBoneScale(targetboneid,scalevec) end
					else
						//Store a non-scaled version of our angles if we're scaling with our target bone
						local matrscl = matr:GetScale()
						if Vector(math.Round(matrscl.x,4), math.Round(matrscl.y,4), math.Round(matrscl.z,4)) != mdlsclvec then
							if parent.AdvBone_Angs and parent.AdvBone_Angs[targetboneid] then
								//Use our target bone's stored angles (plus our ang manip) as our own stored angles if possible
								local angmatr = Matrix()
								angmatr:SetAngles(parent.AdvBone_Angs[targetboneid])
								angmatr:Rotate(self:GetManipulateBoneAngles(i))
								self.AdvBone_Angs[i] = angmatr:GetAngles()
								angmatr = nil
							else
								//Otherwise, rescale the matrix so it's back to normal and store those angles (plus our ang manip)
								local angmatr = Matrix()
								angmatr:Set(matr)
								angmatr:SetScale(mdlsclvec)  //we still want to inherit the overall model scale for things like npcs and animated props
								angmatr:Rotate(self:GetManipulateBoneAngles(i))
								self.AdvBone_Angs[i] = angmatr:GetAngles()
								angmatr = nil
							end
						end
					end

					matr:Translate(self:GetManipulateBonePosition(i))
					matr:Rotate(self:GetManipulateBoneAngles(i))
				end

			else

				//Set our bone to its "default" position, relative to its parent bone on our model

				if i == -1 then
					//Create a matrix for the model origin
					matr = Matrix()
					//If our origin isn't following a bone, then that means it's actually following the parent's origin, so inherit origin manip stuff from it
					if parent.AdvBone_OriginMatrix and self.AdvBone_BoneInfo[i].scale != false then
						matr:Set(parent.AdvBone_OriginMatrix)
					
						matr:Translate(self:GetManipulateBonePosition(-1))
						matr:Rotate(self:GetManipulateBoneAngles(-1))

						//Store a non-scaled version of our angles if we're scaling with the parent origin
						local matrscl = matr:GetScale()
						if Vector(math.Round(matrscl.x,4), math.Round(matrscl.y,4), math.Round(matrscl.z,4)) != mdlsclvec then
							//Use the parent origin's stored angles (plus our ang manip) as our own stored angles if possible
							if parent.AdvBone_Angs and parent.AdvBone_Angs[-1] then
								local angmatr = Matrix()
								angmatr:SetAngles(parent.AdvBone_Angs[-1])
								angmatr:Rotate(self:GetManipulateBoneAngles(-1))
								self.AdvBone_Angs[i] = angmatr:GetAngles()
								angmatr = nil
							end
						end
					else
						matr:SetTranslation(parent:GetPos())
						if parent:IsPlayer() and !parent:InVehicle() then
							//NOTE: Unlike everything else, ent:GetAngles() on players not in vehicles returns 
							//the angle they're facing, not the angle of their model origin, so correct this
							local ang = parent:GetAngles()
							ang.p = 0
							matr:SetAngles(ang)
						else
							matr:SetAngles(parent:GetAngles())
						end

						matr:Scale(mdlsclvec)

						matr:Translate(self:GetManipulateBonePosition(-1))
						matr:Rotate(self:GetManipulateBoneAngles(-1))
					end
				else
					local parentmatr = nil

					local parentboneid = self:GetBoneParent(i)
					if !parentboneid then parentboneid = -1 end
					if parentboneid != -1 then
						//Start with the matrix of our parent bone
						parentmatr = self:GetBoneMatrix(parentboneid)
					else
						//Start with the matrix of the model origin
						parentmatr = Matrix()
						parentmatr:Set(self.AdvBone_OriginMatrix)
					end
				
					if parentmatr then
						if (self.AdvBone_BoneInfo[i].scale != false) then
							//Start off with the parent bone matrix
							matr = parentmatr

							//Store a non-scaled version of our angles if we're scaling with our parent bone
							local matrscl = matr:GetScale()
							if Vector(math.Round(matrscl.x,4), math.Round(matrscl.y,4), math.Round(matrscl.z,4)) != mdlsclvec then
								local angmatr = Matrix()
								angmatr:SetAngles(self.AdvBone_Angs[parentboneid] or matr:GetAngles())
								angmatr:Rotate(self.AdvBone_DefaultBoneOffsets[i].angoffset)
								angmatr:Rotate(self:GetManipulateBoneAngles(i))
								self.AdvBone_Angs[i] = angmatr:GetAngles()
								angmatr = nil
							end

							//Apply pos offset
							matr:Translate(self.AdvBone_DefaultBoneOffsets[i].posoffset)
						else
							//Create a new matrix and just copy over the translation and angle
							matr = Matrix()

							matr:SetTranslation(parentmatr:GetTranslation())
							matr:SetAngles(self.AdvBone_Angs[parentboneid] or parentmatr:GetAngles()) //Use our parent bone's stored angles if possible

							matr:SetScale(mdlsclvec)

							//Apply pos offset - we still want the offset to be multiplied by the parent bone's scale, even if we're not scaling this bone with it
							//(our distance from the parent bone should be the same regardless of whether we're scaling with it or not - otherwise we'd
							//end up embedded inside the parent bone if it was scaled up, or end up far away from it if it was scaled down)
							local tr1 = parentmatr:GetTranslation()
							parentmatr:Translate(self.AdvBone_DefaultBoneOffsets[i].posoffset)
							local tr2 = parentmatr:GetTranslation()
							local posoffsetscaled = WorldToLocal(tr2, Angle(), tr1, matr:GetAngles())
							matr:Translate(posoffsetscaled / mdlscl)
						end

						//Apply pos manip and ang offset+manip
						matr:Translate(self:GetManipulateBonePosition(i))
						matr:Rotate(self.AdvBone_DefaultBoneOffsets[i].angoffset)
						matr:Rotate(self:GetManipulateBoneAngles(i))
					end
				end

			end


			if matr then  //matr can be nil if we're visible but our parent isn't

				//Store a non-scaled version of our angles if we're scaling
				local scale = self:GetManipulateBoneScale(i)
				if !self.AdvBone_Angs[i] and scale != Vector(1,1,1) then
					self.AdvBone_Angs[i] = matr:GetAngles()
				end
				//Apply scale manip
				matr:Scale(scale)


				if !self.AdvBone_BoneHitBoxes then //used by bloat
					local ourscale = matr:GetScale()
					highestbonescale = math.max(ourscale.x,ourscale.y,ourscale.z,highestbonescale)
				end

				if i == -1 then
					self.AdvBone_OriginMatrix = matr

					//Move our actual model origin with the origin control
					self:SetPos(matr:GetTranslation())
					self:SetAngles(self.AdvBone_Angs[-1] or matr:GetAngles())
					//Also move our render origin - setpos alone is unreliable since the position can get reasserted if the parent moves or something like that
					self:SetRenderOrigin(matr:GetTranslation())
					self:SetRenderAngles(self.AdvBone_Angs[-1] or matr:GetAngles())
				else
					//Get the min and max positions of our bones ("bone bounds") for our render bounds calculation to use
					local bonepos = nil
					local hitboxmin, hitboxmax = nil, nil
					if !self.SavedLocalBonePositions[i] or !self.SavedBoneMatrices[i] or matr:GetTranslation() != self.SavedBoneMatrices[i]:GetTranslation() or matr:GetAngles() != self.SavedBoneMatrices[i]:GetAngles() then
						//bonepos = WorldToLocal(matr:GetTranslation(), Angle(), self:GetPos(), self:GetAngles())
						bonepos = WorldToLocal(matr:GetTranslation(), Angle(), parent:GetPos(), parent:GetAngles())
						if self.AdvBone_BoneHitBoxes[i] then
							//local pos = matr:GetTranslation()
							local scl = matr:GetScale()
							local pmins = self.AdvBone_BoneHitBoxes[i].min * scl
							local pmaxs = self.AdvBone_BoneHitBoxes[i].max * scl
							local vects = {
								pmins, Vector(pmaxs.x, pmins.y, pmins.z),
								Vector(pmins.x, pmaxs.y, pmins.z), Vector(pmaxs.x, pmaxs.y, pmins.z),
								Vector(pmins.x, pmins.y, pmaxs.z), Vector(pmaxs.x, pmins.y, pmaxs.z),
								Vector(pmins.x, pmaxs.y, pmaxs.z), pmaxs,
							}
							for i = 1, #vects do
								local wspos = LocalToWorld(vects[i], Angle(), matr:GetTranslation(), matr:GetAngles())
								wspos = WorldToLocal(wspos, Angle(), parent:GetPos(), parent:GetAngles()) //renderbounds are relative to the parent, because renderorigin/renderangles don't affect them
								vects[i] = wspos
							end
							hitboxmin = Vector( math.min(vects[1].x, vects[2].x, vects[3].x, vects[4].x, 
									vects[5].x, vects[6].x, vects[7].x, vects[8].x),
									math.min(vects[1].y, vects[2].y, vects[3].y, vects[4].y, 
									vects[5].y, vects[6].y, vects[7].y, vects[8].y),
									math.min(vects[1].z, vects[2].z, vects[3].z, vects[4].z, 
									vects[5].z, vects[6].z, vects[7].z, vects[8].z) )
							hitboxmax = Vector( math.max(vects[1].x, vects[2].x, vects[3].x, vects[4].x, 
									vects[5].x, vects[6].x, vects[7].x, vects[8].x),
									math.max(vects[1].y, vects[2].y, vects[3].y, vects[4].y, 
									vects[5].y, vects[6].y, vects[7].y, vects[8].y),
									math.max(vects[1].z, vects[2].z, vects[3].z, vects[4].z, 
									vects[5].z, vects[6].z, vects[7].z, vects[8].z) )
							self.SavedLocalHitBoxes[i] = {min = hitboxmin, max = hitboxmax}
						end
						self.SavedLocalBonePositions[i] = bonepos
					else
						//If the bone hasn't moved at all then just use the old position instead of calling WorldToLocal again
						bonepos = self.SavedLocalBonePositions[i]
						if self.SavedLocalHitBoxes[i] then
							hitboxmin = self.SavedLocalHitBoxes[i].min
							hitboxmax = self.SavedLocalHitBoxes[i].max
						end
					end

					local function SetBoneMinsMaxs(vec)
						if !bonemins and !bonemaxs then
							bonemins = Vector()
							bonemaxs = Vector()
							bonemins:Set(vec)
							bonemaxs:Set(vec)
						else
							bonemins.x = math.min(vec.x,bonemins.x)
							bonemins.y = math.min(vec.y,bonemins.y)
							bonemins.z = math.min(vec.z,bonemins.z)
							bonemaxs.x = math.max(vec.x,bonemaxs.x)
							bonemaxs.y = math.max(vec.y,bonemaxs.y)
							bonemaxs.z = math.max(vec.z,bonemaxs.z)
						end
					end
					if hitboxmin and hitboxmax then
						SetBoneMinsMaxs(hitboxmin)
						SetBoneMinsMaxs(hitboxmax)
						//debugoverlay.BoxAngles(parent:GetPos(), hitboxmin, hitboxmax, parent:GetAngles(), 0.1, Color(255,255,0,0))
					else
						SetBoneMinsMaxs(bonepos)
					end
						
					//Apply the bone matrix
					if self:GetBoneName(i) != "__INVALIDBONE__" then
						self:SetBoneMatrix(i,matr)

						//For sleep status, save bone matrices to table, and compare with previous table to tell if they've changed
						if !BonesHaveChanged and matr != self.SavedBoneMatrices[i] then
							//MsgN(self:GetBoneName(i), "\n", matr, "\n != \n", self.SavedBoneMatrices[i], "\n")
							//if !self.SavedBoneMatrices[i] then
								BonesHaveChanged = true
							//else
							//	local m1 = {matr:Unpack()}
							//	local m2 = {self.SavedBoneMatrices[i]:Unpack()}
							//	for k, v in pairs (m1) do
							//		if !BonesHaveChanged then
							//			if math.Round(m1[k],4) != math.Round(m2[k],4) then
							//				MsgN(self:GetModel(), " ", self:GetBoneName(i), ": ", m1[k], " wasn't equal to ", m2[k])
							//				BonesHaveChanged = true
							//			end
							//		end
							//	end
							//end
						end
						self.SavedBoneMatrices[i] = matr

						//Note: Jigglebones currently don't work because their procedurally generated matrix is replaced with the one we're giving them here.
						//We can detect jigglebones specifically with self:BoneHasFlag(i,BONE_ALWAYS_PROCEDURAL), but I'm not sure what we could do with them.
					end
				end

			end

		end

		self.AdvBone_RenderBounds_HighestBoneScale = highestbonescale
		self.AdvBone_RenderBounds_BoneMins = bonemins
		self.AdvBone_RenderBounds_BoneMaxs = bonemaxs
		//debugoverlay.BoxAngles(parent:GetPos(), bonemins, bonemaxs, parent:GetAngles(), 0.1, Color(0,255,0,0))

		if BonesHaveChanged then
			self.LastBoneChangeTime = curtime
		end
	end

	function ENT:CalcAbsolutePosition(pos, ang)
		//Wake up the BuildBonePositions function whenever the entity moves
		//Note: This will be running every frame for animprops merged to animating entities because the advbonemerge constraint uses FollowBone for some reason I don't recall (exposes more bones?)
		if self.AdvBone_BoneInfo then
			self.LastPos = self.LastPos or pos
			self.LastAng = self.LastAng or ang
			if pos != self.LastPos or ang != self.LastAng then
				//MsgN(self:GetModel(), " calcabs: pos ", pos, " ang ", ang)
				self.LastBoneChangeTime = CurTime()
				self.LastPos = pos
				self.LastAng = ang
			end
		end
	end
end




//Boneinfo networking - 
//Step 1: If we're the client and we don't have a boneinfo table, request it from the server.
//Step 2: If we're the server and we receive a request, send a boneinfo table.
//Step 3: If we're the client and we receive a boneinfo table, use it.

//AdvBone_EntBoneInfoTable_GetFromSv structure:
//	Entity: Entity that needs a BoneInfo table

//AdvBone_EntBoneInfoTable_SendToCl structure:
//	Entity: Entity that needs a BoneInfo table
//
//	Int(9): Number of BoneInfo entries
//	FOR EACH ENTRY:
//		Int(9): Key for this entry (bone index)
//
//		Int(9): Target bone index
//		Bool: Follow target bone scale

if SERVER then 

	util.AddNetworkString("AdvBone_EntBoneInfoTable_GetFromSv")
	util.AddNetworkString("AdvBone_EntBoneInfoTable_SendToCl")


	//If we received a request for a boneinfo table, then send it to the client
	net.Receive("AdvBone_EntBoneInfoTable_GetFromSv", function(_, ply)
		local ent = net.ReadEntity()
		if !IsValid(ent) or !ent.AdvBone_BoneInfo then return end

		net.Start("AdvBone_EntBoneInfoTable_SendToCl", true)
			net.WriteEntity(ent)

			net.WriteInt(table.Count(ent.AdvBone_BoneInfo), 9)
			for key, entry in pairs (ent.AdvBone_BoneInfo) do
				net.WriteInt(key, 9)

				local parent = ent:GetParent()
				if IsValid(parent) then
					if parent.AttachedEntity then parent = parent.AttachedEntity end
					net.WriteInt(parent:LookupBone(entry.parent) or -1, 9)
				else
					net.WriteInt(-1, 9)
				end
				net.WriteBool(entry.scale)
			end
		net.Send(ply)

		//Also, now that we know the entity has initlalized on the client, we can send it the bonemanips as well
		ent.AdvBone_BoneManips_Sent = ent.AdvBone_BoneManips_Sent or {}
		if ent.AdvBone_BoneManips and !ent.AdvBone_BoneManips_Sent[ply] then
			for boneID, tab in pairs (ent.AdvBone_BoneManips) do
				if tab.p then
					net.Start("AdvBone_BoneManipPos_SendToCl")
						net.WriteEntity(ent)
						net.WriteInt(boneID, 9)
						net.WriteVector(tab.p)
					net.Send(ply)
				end
				if tab.a then
					net.Start("AdvBone_BoneManipAng_SendToCl")
						net.WriteEntity(ent)
						net.WriteInt(boneID, 9)
						net.WriteAngle(tab.a)
					net.Send(ply)
				end
				if tab.s then
					net.Start("AdvBone_BoneManipScale_SendToCl")
						net.WriteEntity(ent)
						net.WriteInt(boneID, 9)
						net.WriteVector(tab.s)
					net.Send(ply)
				end
			end
			ent.AdvBone_BoneManips_Sent[ply] = true
		end
	end)

end

if CLIENT then

	//If we received a boneinfo table from the server, then use it
	net.Receive("AdvBone_EntBoneInfoTable_SendToCl", function()
		local ent = net.ReadEntity()
		local parent = nil

		if IsValid(ent) then
			parent = ent:GetParent()
			if IsValid(parent) then
				//Make sure we get the right results from GetBoneName - if the client hasn't seen the model yet then it might return __INVALIDBONE__ when it shouldn't
				if parent.AttachedEntity then parent = parent.AttachedEntity end
				parent:DrawModel()
				parent:SetupBones()
			end
		end

		local count = net.ReadInt(9)
		local tab = {}
		for i = 1, count do
			local key = net.ReadInt(9)

			//Note: tried making clientside boneinfo use a boneid int for parent instead of a string that gets LookupBone()'d every time, but there was no difference in perf,
			//so instead we'll keep using a string for consistency between server/client
			local parentstr = ""
			local parentint = net.ReadInt(9)
			if IsValid(ent) and IsValid(parent) then
				parentstr = parent:GetBoneName(parentint)
				if parentstr == "__INVALIDBONE__" then parentstr = "" end
			end

			tab[key] = {
				parent = parentstr,
				scale = net.ReadBool(),
			}
		end
		
		if IsValid(ent) and (IsValid(parent) or ent:GetClass() == "prop_animated") and !ent.AdvBone_BoneInfo_Received then
			//BUG: In some instances, entities "merged via constraint" will initially receive a mangled boneinfo table with exactly the same contents every time (with a lot of
			//useless keys such as a bone -256). Serverside, the table being sent is fine - the issue only occurs on the client's end, when receiving it. These tables are always
			//caught by the above condition, because for some reason, whenever these tables are received, ent:GetParent() is always invalid (even though the parent IS valid when 
			//the entity requests the table from the server in the first place??) but this shouldn't be considered a reliable fix because this is clearly a symptom of a much more
			//complicated problem. Don't be surprised if this comes up again.
			//UPDATE 3-8-18: This came up again with boneinfo tables on prop_animated, but turned out to just be the result of bad networking (net.Writes not matching net.Reads).
			//Maybe look into this again and try to actually fix the problem, now that we know it's not as inscrutable as we thought?
			local keys = {}
			for k, _ in pairs (tab) do
				table.insert(keys, k)
			end
			if math.min(unpack(keys)) < -1 then //this shouldn't ever happen - see above
				MsgN(ent, " (", ent:GetModel(), "): received garbage boneinfo table, not using") 
				return
			end
			ent.AdvBone_BoneInfo = tab
			ent.AdvBone_BoneInfo_Received = true
			ent.LastBoneChangeTime = CurTime()
		end
	end)


	function ENT:Think()

		//Fix for demo recording and playback - when demos are recorded, they wipe a bunch of clientside settings like LODs and our BuildBonePositions callback, so redo those by running Initialize.
		//They also don't seem to record clientside values set on the entity before recording, so tell the server to send us a new BoneInfo table so we can actually record this one.
		//Note 10/16/24: Newly connected players also do this, they run Initialize but then wipe the callback and LOD setting right after, so check them as well using self.BuildBonePositions_HasRun.
		if (!self.BuildBonePositions_HasRun or engine.IsRecordingDemo()) and #self:GetCallbacks("BuildBonePositions") == 0 then
			self:Initialize()
			self.AdvBone_BoneInfo_Received = false
		end

		local parent = self:GetParent()
		if !IsValid(parent) then parent = nil end
		local curtime = CurTime()
		if parent then
			if parent.AttachedEntity then parent = parent.AttachedEntity end

			//If we don't have a clientside boneinfo table, or need to update it, then request it from the server
			if !self.AdvBone_BoneInfo_Received then
				net.Start("AdvBone_EntBoneInfoTable_GetFromSv", true)
					net.WriteEntity(self)
				net.SendToServer()
			end

			if self:GetModelScale() != parent:GetModelScale() then
				self:SetModelScale(parent:GetModelScale())
			end

			//We need to make the parent setup its bones an extra time in Think or else the merged ents' render positions get weird when attached to some ents (TODO: what ents?)
			//(this doesn't seem to have much of any performance impact so it's fine)
			if parent.AdvBone_LastParentSetupBonesTime != curtime then
				parent:SetLOD(0)
				parent:SetupBones()
				parent.AdvBone_LastParentSetupBonesTime = curtime
			end
		end

		//We can't remove the clientside model inside the BuildBonePositions callback, or else it'll cause a crash for some reason - do it here instead
		if self.csmodeltoremove then
			self.csmodeltoremove:Remove()
			self.csmodeltoremove = nil
		end


		//Workaround: If our model has only a single bone named "static_prop", then the BuildBonePositions callback won't run, so we can't move the bone the usual way. Instead, do 
 		//some trickery here with ApplyMatrix, where we work with a matrix for the single bone (actually an origin control in disguise) using a stripped-down version of our
		//BuildBonePositions function, and then apply that matrix to the entire model.
		local IsStaticProp = false
		if self:GetBoneName(0) == "static_prop" then
			IsStaticProp = true

			//Set values used for render bounds calculation - these are simple since we only have one bone in the same spot as our origin
			if !self.AdvBone_RenderBounds_Bloat then
				local modelmins, modelmaxs = self:GetModelRenderBounds()
				self.AdvBone_RenderBounds_Bloat = math.max(0, -modelmins.x, -modelmins.y, -modelmins.z, modelmaxs.x, modelmaxs.y, modelmaxs.z) * 1.75 //because of the rendermultiply method we're using for the matrix, the bounds will never actually rotate, so make sure the bounds are big enough that nothing sticks through when we rotate the model
				self.AdvBone_RenderBounds_BoneMins = Vector(0,0,0)
				self.AdvBone_RenderBounds_BoneMaxs = Vector(0,0,0)
			end


			if !IsValid(self) then return end
			if !self.AdvBone_BoneInfo then return end

			if !parent then return end

			--[[//this is a redundant call i'm pretty sure, unless there's some weird circumstance where the curtime from earlier is somehow already outdated (function getting called a lot?)
			//Multiple merged ents can call SetupBones on the same parent, so make sure we only do this once per frame
			if parent.AdvBone_LastParentSetupBonesTime != CurTime() then
				MsgN("static_prop workaround: not a redundant call after all!")
				parent:SetLOD(0)
				parent:SetupBones()
				parent.AdvBone_LastParentSetupBonesTime = CurTime()
			end]]

			local mdlscl = math.Round(self:GetModelScale(),4) //we need to round these values or else the game won't think they're equal
			local mdlsclvec = Vector(mdlscl,mdlscl,mdlscl)

			//scaling a matrix down can distort its angles (or remove them entirely if scaled down to 0), so whenever we scale a matrix, we'll store its non-scaled angles in here
			//first. whenever another bone wants to follow that matrix but NOT scale with it, it'll use the stored angles from this table instead.
			self.AdvBone_Angs = {}  


			local matr = nil
			local targetboneid = parent:LookupBone(self.AdvBone_BoneInfo[0].parent)
			if targetboneid then

				//Set our bone to the matrix of its target bone on the other model

				local targetmatr = parent:GetBoneMatrix(targetboneid)
				if targetmatr then

					if parent.AdvBone_StaticPropMatrix and self.AdvBone_BoneInfo[0].parent == "static_prop" then
						//The static_prop workaround uses some nonsense with EnableMatrix/RenderMultiply to work, so the matrix we retrieve here 
						//won't have the right angles or scale. Use a stored matrix with the proper values instead.
						targetmatr:Set(parent.AdvBone_StaticPropMatrix)
					end

					matr = targetmatr

					if (self.AdvBone_BoneInfo[0].scale == false) then
						//Since we don't want to use the target bone's scale, rescale the matrix so it's back to normal
						matr:SetScale(mdlsclvec)  //we still want to inherit the overall model scale for things like npcs and animated props

						if parent.AdvBone_Angs and parent.AdvBone_Angs[targetboneid] then
							//Use our target bone's stored angles if possible
							matr:SetAngles(parent.AdvBone_Angs[targetboneid])
						end

						//If the target bone's scale is under 0.04 on any axis, then we can't scale it back up properly, so let's fix that
						//We can't just create a new matrix instead and copy over the translation and angles, since 0-scale matrices lose their angle info
						local scalevec = parent:GetManipulateBoneScale(targetboneid)
						local scalefix = false
						if scalevec.x < 0.04 then scalevec.x = 0.05 scalefix = true end
						if scalevec.y < 0.04 then scalevec.y = 0.05 scalefix = true end
						if scalevec.z < 0.04 then scalevec.z = 0.05 scalefix = true end
						if scalefix == true then parent:ManipulateBoneScale(targetboneid,scalevec) end
					else
						//Store a non-scaled version of our angles if we're scaling with our target bone
						local matrscl = matr:GetScale()
						if Vector(math.Round(matrscl.x,4), math.Round(matrscl.y,4), math.Round(matrscl.z,4)) != mdlsclvec then
							if parent.AdvBone_Angs and parent.AdvBone_Angs[targetboneid] then
								//Use our target bone's stored angles (plus our ang manip) as our own stored angles if possible
								local angmatr = Matrix()
								angmatr:SetAngles(parent.AdvBone_Angs[targetboneid])
								angmatr:Rotate(self:GetManipulateBoneAngles(0))
								self.AdvBone_Angs[0] = angmatr:GetAngles()
								self.AdvBone_Angs[-1] = angmatr:GetAngles()
								angmatr = nil
							else
								//Otherwise, rescale the matrix so it's back to normal and store those angles (plus our ang manip)
								local angmatr = Matrix()
								angmatr:Set(matr)
								angmatr:SetScale(mdlsclvec)  //we still want to inherit the overall model scale for things like npcs and animated props
								angmatr:Rotate(self:GetManipulateBoneAngles(0))
								self.AdvBone_Angs[0] = angmatr:GetAngles()
								self.AdvBone_Angs[-1] = angmatr:GetAngles()
								angmatr = nil
							end
						end
					end

					matr:Translate(self:GetManipulateBonePosition(0))
					matr:Rotate(self:GetManipulateBoneAngles(0))
				end

			else

				//Set our bone to its "default" position, relative to its parent bone on our model

				//Create a matrix for the model origin
				matr = Matrix()
				//If our origin isn't following a bone, then that means it's actually following the parent's origin, so inherit origin manip stuff from it
				if parent.AdvBone_OriginMatrix and self.AdvBone_BoneInfo[0].scale != false then
					matr:Set(parent.AdvBone_OriginMatrix)
					
					matr:Translate(self:GetManipulateBonePosition(0))
					matr:Rotate(self:GetManipulateBoneAngles(0))

					//Store a non-scaled version of our angles if we're scaling with the parent origin
					local matrscl = matr:GetScale()
					if Vector(math.Round(matrscl.x,4), math.Round(matrscl.y,4), math.Round(matrscl.z,4)) != mdlsclvec then
						//Use the parent origin's stored angles (plus our ang manip) as our own stored angles if possible
						if parent.AdvBone_Angs and parent.AdvBone_Angs[-1] then
							local angmatr = Matrix()
							angmatr:SetAngles(parent.AdvBone_Angs[-1])
							angmatr:Rotate(self:GetManipulateBoneAngles(0))
							self.AdvBone_Angs[0] = angmatr:GetAngles()
							self.AdvBone_Angs[-1] = angmatr:GetAngles()
							angmatr = nil
						end
					end
				else
					matr:SetTranslation(parent:GetPos())
					if parent:IsPlayer() and !parent:InVehicle() then
						//NOTE: Unlike everything else, ent:GetAngles() on players not in vehicles returns 
						//the angle they're facing, not the angle of their model origin, so correct this
						local ang = parent:GetAngles()
						ang.p = 0
						matr:SetAngles(ang)
					else
						matr:SetAngles(parent:GetAngles())
					end

					matr:Scale(mdlsclvec)

					matr:Translate(self:GetManipulateBonePosition(0))
					matr:Rotate(self:GetManipulateBoneAngles(0))
				end

			end


			if matr then  //matr can be nil if we're visible but our parent isn't

				//Store a non-scaled version of our angles if we're scaling
				local scale = self:GetManipulateBoneScale(0)
				if !self.AdvBone_Angs[0] and scale != Vector(1,1,1) then 
					self.AdvBone_Angs[0] = matr:GetAngles()
					self.AdvBone_Angs[-1] = matr:GetAngles()
				end
				//Apply scale manip
				matr:Scale(scale)

				local ourscale = matr:GetScale()
				self.AdvBone_RenderBounds_HighestBoneScale = math.max(ourscale.x,ourscale.y,ourscale.z)


				//Save the retrievable matrix now, before we have to change a bunch of stuff to get it to work with EnableMatrix
				self.AdvBone_StaticPropMatrix = Matrix()
				self.AdvBone_StaticPropMatrix:Set(matr)
				self.AdvBone_OriginMatrix = self.AdvBone_StaticPropMatrix //things following the origin should use this matrix too


				local matrscl = matr:GetScale()
				local mergedgrip = self:GetPartCtrl_MergedGrip()
				if !mergedgrip and (self.AdvBone_StaticPropUsedRenderMultiply or Vector(math.Round(matrscl.x,4),math.Round(matrscl.y,4),math.Round(matrscl.z,4)) != mdlsclvec) then
					//Because EnableMatrix's scale is multiplicative, we actually need to counteract the model scale before applying it to ourselves or else it'll be doubled
					matr:SetScale( Vector(ourscale.x / mdlscl, ourscale.y / mdlscl, ourscale.z / mdlscl) )

					//Apply the matrix to our model
					self:SetPos(matr:GetTranslation())
					self:SetRenderOrigin(matr:GetTranslation())

					matr:SetTranslation(vector_origin)
					self:SetRenderAngles(angle_zero) //this method sucks because self:GetAngles() will return (0,0,0), but we can't rotate the matrix instead because that'll mess up the scaling
					self:EnableMatrix("RenderMultiply", matr)

					//EnableMatrix/RenderMultiply doesn't modify the model's shadow properly (the shadow casted will be unrotated and unscaled), 
					//so unfortunately we'll have to get rid of the shadow
					self:DestroyShadow()
					self.AdvBone_StaticPropUsedRenderMultiply = true
				else
					if mergedgrip then
						self:SetModelScale(0)
						self:DestroyShadow()
					end
					//If we aren't scaling the model then we don't need to use enablematrix - unfortunately, this breaks after using EnableMatrix 
					//(and DisableMatrix doesn't fix it) so we can't do this if we've scaled the entity before
					self:SetPos(matr:GetTranslation())
					self:SetAngles(self.AdvBone_Angs[-1] or matr:GetAngles())
					//Also move our render origin - setpos alone is unreliable since the position can get reasserted if the parent moves or something like that
					self:SetRenderOrigin(matr:GetTranslation())
					self:SetRenderAngles(self.AdvBone_Angs[-1] or matr:GetAngles())

					//if self.AdvBone_StaticPropUsedRenderMultiply then
					//	self:DisableMatrix("RenderMultiply")
					//	self:CreateShadow()
					//	self.AdvBone_StaticPropRenderMultiply = nil
					//end
				end

			end
		end


		//Set the render bounds
		if !parent or !self.AdvBone_RenderBounds_BoneMins or !self.AdvBone_RenderBounds_HighestBoneScale then return end
		if IsStaticProp or !(self.LastBoneChangeTime + (FrameTime() * 10) < curtime) then //same check as BuildBonePosition's "skip" - don't update this stuff if the bones haven't moved in a while
			local bloat = nil
			if self.AdvBone_RenderBounds_Bloat then
				bloat = self.AdvBone_RenderBounds_Bloat * self.AdvBone_RenderBounds_HighestBoneScale
				bloat = Vector(bloat, bloat, bloat)
			end
			local min, max = self.AdvBone_RenderBounds_BoneMins, self.AdvBone_RenderBounds_BoneMaxs
			if !IsStaticProp then
				local min2, max2 = parent:GetRenderBounds()
				//adding the parent's render bounds is necessary in order to prevent shadows from getting cut off in some cases i.e. when merged to ragdolls or animprops
				min, max = Vector(math.min(min.x,min2.x),math.min(min.y,min2.y),math.min(min.z,min2.z)), Vector(math.max(max.x,max2.x),math.max(max.y,max2.y),math.max(max.z,max2.z))
			end
			self:SetRenderBounds(min, max, bloat)

			//debug: draw render bounds
			--[[local min, max = self:GetRenderBounds()
			debugoverlay.BoxAngles(parent:GetPos(), min, max, parent:GetAngles(), 0.1, Color(0,255,150,0))]]

			local focus = system.HasFocus()
			if focus == nil or focus == true then //updating shadows out of focus can cause a crash with the GPU Saver addon
				parent:UpdateShadow()
			end
		end


		self:NextThink(curtime)
		//return true

	end


	local AdvBone_IsSkyboxDrawing = false

	hook.Add("PreDrawSkyBox", "AdvBone_IsSkyboxDrawing_Pre", function()
		AdvBone_IsSkyboxDrawing = true
	end)

	hook.Add("PostDrawSkyBox", "AdvBone_IsSkyboxDrawing_Post", function()
		AdvBone_IsSkyboxDrawing = false
	end)

	function ENT:Draw(flag)

		//try to prevent this from being rendered additional times if it has a child with EF_BONEMERGE; TODO: i can't find any situation where this breaks anything, but it still feels like it could.
		if flag == 0 then
			return
		end

		//Don't draw in the 3D skybox if our renderbounds are clipping into it but we're not actually in there
		//(common problem for ents with big renderbounds on gm_flatgrass, where the 3D skybox area is right under the floor)
		if AdvBone_IsSkyboxDrawing and !self:GetNWBool("IsInSkybox") then return end
		//TODO: Fix opposite condition where ent renders in the world from inside the 3D skybox area (i.e. gm_construct) - we can't just do the opposite of this because
		//we still want the ent to render in the world if the player is also in the 3D skybox area with them, but we can't detect if the player is in that area clisntside

		//Don't render until we've got our boneinfo table
		if !self.AdvBone_BoneInfo then return end

		//Don't draw ents attached to the player in first person view
		local function GetTopmostParentPlayer(ent)
			//Keep going up the parenting hierarchy until we get to localplayer.
			local par = ent:GetParent()
			if IsValid(par) then
				if par == LocalPlayer() then
					return par
				else
					return GetTopmostParentPlayer(par)
				end
			end
		end
		if GetTopmostParentPlayer(self) then
			shoulddraw = LocalPlayer():ShouldDrawLocalPlayer()
			if !shoulddraw then
				if !self.RemovedLocalplayerShadow then
					self.RemovedLocalplayerShadow = true
					self:DestroyShadow()
				end
				return
			elseif shoulddraw and self.RemovedLocalplayerShadow then
				self.RemovedLocalplayerShadow = nil
				self:CreateShadow()
			end
		end

		self:DrawModel()
		self.HasDrawn = true //fix: don't let buildbonepositions fall asleep if we spawned offscreen and haven't been seen by the client yet, otherwise it'll save bad bone positions

	end

	//function ENT:DrawTranslucent()
	//
	//	self:Draw()
	//
	//end


end




if SERVER then

	//"Unmerge" function - uses the info saved to self.AdvBone_UnmergeInfo to reconstruct the original entity that was bonemerged, and then removes us

	function ENT:Unmerge(ply)
	
		if !IsValid(self) then return end
		if !self:GetBoneCount() then return end
		local parent = self:GetParent()
		if !IsValid(parent) then return end

		local enttable = self.AdvBone_UnmergeInfo
		if enttable then
			//Correct values that have been changed by utilities since merging
			//Face poser
			local flexscalenew = self:GetFlexScale()
			if enttable.FlexScale != flexscalenew then enttable.FlexScale = flexscalenew end
			local flexnew = nil
			for i = 0, self:GetFlexNum() do
				local w = self:GetFlexWeight(i)
				if w != 0 then
					flexnew = flexnew or {}
					flexnew[i] = w
				end
			end
			if enttable.Flex != flexnew then enttable.Flex = flexnew end
			//Eye poser
			if self.EntityMods and self.EntityMods.eyetarget then
				local eyetargetnew = self.EntityMods.eyetarget
				if !enttable.EntityMods then enttable.EntityMods = {} end
				if enttable.EntityMods.eyetarget != eyetargetnew then enttable.EntityMods.eyetarget = table.Copy(eyetargetnew) end
			end
			//Bodygroups
			local bg = self:GetBodyGroups()
			local bgnew = nil
			if bg then
				for k, v in pairs(bg) do
					if self:GetBodygroup(v.id) > 0 then
						bgnew = bgnew or {}
						bgnew[v.id] = self:GetBodygroup(v.id)
					end
				end
			end
			if enttable.BodyG != bgnew then enttable.BodyG = bgnew end
			//Skin
			if enttable.Skin != self:GetSkin() then enttable.Skin = self:GetSkin() end

			//Fix: Due to a badly written function in the duplicator module (PhysicsObject.Load - lua/includes/modules/duplicator.lua:67, uses "Entity" value not defined anywhere in the function), 
			//using duplicator.Paste here to paste a frozen physobj causes errors. I have no idea why it still works when called by the duplicator itself because it has the same value there, but
			//that's not important. Get rid of all the "Frozen" entries in our PhysicsObjects table, we're going to freeze them again ourselves anyway.
			if enttable.PhysicsObjects then
				for k, v in pairs (enttable.PhysicsObjects) do
					if v.Frozen then
						enttable.PhysicsObjects[k].Frozen = false
					end
				end
			end

			local dupedenttab, _ = duplicator.Paste(ply, {enttable}, {})
			local newent = dupedenttab[1]
			if !IsValid(newent) then return end

			//If our newent is a prop_effect, then copy the bone manips over to the attachedentity instead
			local target = newent
			if newent.AttachedEntity then target = newent.AttachedEntity end  //this is a bit backwards from how the merging function does it, but hey

			//Copy BoneInfo table, but only if the player has modified the table since merging.
			//Explanation: When an entity is first merged, it saves a value called ent.AdvBone_BoneInfo_IsDefault. This value is removed once the player modifies the table or 
			//saves the entity. This means if the player hasn't changed the table from the default, it won't be saved, so if they made a mistake and had "merge matching bones 
			//by default" set to the wrong setting, they can unmerge the entity, change the setting, and merge it again without being stuck with a default table they don't want.
			if !self.AdvBone_BoneInfo_IsDefault or newent:GetClass() == "prop_animated" then
				newent.AdvBone_BoneInfo = self.AdvBone_BoneInfo
			end
			//If we're a disabled prop_animated that had our IsDefault value changed while we were converted to an ent_advbonemerge, then save the new value.
			//(prop_animated is the only entity that stores its IsDefault value while unmerged, because it still does AdvBone stuff by itself)
			if newent:GetClass() == "prop_animated" then
				//MsgN("unmerging a disabled prop_animated, IsDefault = ", self.AdvBone_BoneInfo_IsDefault)
				newent.AdvBone_BoneInfo_IsDefault = self.AdvBone_BoneInfo_IsDefault
			end

			//Copy bone manips - store both advbone manips and garrymanips so that advbone manips are restored on re-merge, but garrymanips are shown on the prop while unmerged
			target.AdvBone_BoneManips = self.AdvBone_BoneManips
			for i = -1, self:GetBoneCount() - 1 do
				local p = self:GetManipulateBonePosition(i)
				local a = self:GetManipulateBoneAngles(i)
				local s = self:GetManipulateBoneScale(i)

				if ( p != vector_origin ) then target:ManipulateBonePosition(i, p) end
				if ( a != angle_zero ) then target:ManipulateBoneAngles(i, a) end
				if ( s != Vector(1,1,1) ) then target:ManipulateBoneScale(i, s) end
				//target:ManipulateBoneJiggle(i, self:GetManipulateBoneJiggle(i))  //i'm not sure if this actually does anything
			end

			//Copy over DisableBeardFlexifier, so that we can restore it if the ent is re-merged
			newent:SetNWBool("DisableBeardFlexifier", self:GetNWBool("DisableBeardFlexifier"))

			timer.Simple(0.1, function()	//we need to move the physics objects a bit after the entity has spawned - if we do it at the same time, then the physobjs won't wake up for some reason, and ragdolls will still appear to be at their old location until something bumps into them
				if !IsValid(newent) or !IsValid(ply) then return end
				if !IsValid(parent) then newent:Remove() return end //fix a case where attached ents would get unmerged upon parent's deletion sometimes and cause errors

				local _, bboxtop1 = parent:GetRotatedAABB(parent:GetCollisionBounds())
				local bboxtop2, _ = newent:GetRotatedAABB(newent:GetCollisionBounds())
				local height = bboxtop1.z + -bboxtop2.z + parent:GetPos().z

				//if newent has multiple physics objects, then we need to move all of the physics objects individually
				if newent:GetPhysicsObjectCount() > 1 then
					for i = 0, newent:GetPhysicsObjectCount() - 1 do
						local phys = newent:GetPhysicsObjectNum(i)
						phys:SetPos(Vector(parent:GetPos().x, parent:GetPos().y, height) + (phys:GetPos() - newent:GetPos()))
						phys:Wake()
						phys:EnableMotion(false)
						ply:AddFrozenPhysicsObject(nil, phys)  //the entity argument needs to be nil, or else it'll make unnecessary halo effects and lag up the game
					end
				end

				newent:SetPos(Vector(parent:GetPos().x, parent:GetPos().y, height))
				local phys = newent:GetPhysicsObject()
				if IsValid(phys) then
					phys:Wake()
					phys:EnableMotion(false)
					ply:AddFrozenPhysicsObject(nil, phys)  //the entity argument needs to be nil, or else it'll make unnecessary halo effects and lag up the game
				end
			end)

			if !self:GetPartCtrl_MergedGrip() then //unmerged particle grips don't need an undo, because we already have a separate one for the particle itself
				//Add an undo entry
				local printname = newent:GetClass() or "Entity"
				if newent.PrintName and newent.PrintName != "" then printname = tostring(newent.PrintName) end
				if printname == "prop_ragdoll" then printname = "Ragdoll" end
				if printname == "prop_physics" then printname = "Prop" end
				if printname == "prop_effect" then printname = "Effect" end
				undo.Create("SENT")
					undo.SetPlayer(ply)
					undo.AddEntity(newent)
					undo.SetCustomUndoText("Undone Unmerged " .. printname)
				undo.Finish("Unmerged " .. printname .. " (" .. newent:GetModel() .. ")")
			end

			//Get all of the constraints directly attached to us, and copy them over to newent.
			local oldentconsts = constraint.GetTable(self)
			for k, const in pairs (oldentconsts) do
				if const.Entity then
					if !(const.Type == "AdvBoneMerge" and const.Entity[1].Entity == parent and const.Entity[2].Entity == self) then	//make sure we don't copy the constraint that bonemerges us to our parent
						//If any of the values in the constraint table are us, switch them over to newent
						for key, val in pairs (const) do
							if val == self then 
								const[key] = newent
							//Transfer over bonemerged ents from other addons' bonemerge constraints, and make sure they don't get DeleteOnRemoved
							elseif (const.Type == "EasyBonemerge" or const.Type == "CompositeEntities_Constraint" 
							or const.Type == "PartCtrl_Ent" or const.Type == "PartCtrl_SpecialEffect") //doesn't work for BoneMerge, bah
							and isentity(val) and IsValid(val) and val:GetParent() == self then
								//MsgN("reparenting ", val:GetModel(), " ", val, " to ", newent)
								if const.Type == "CompositeEntities_Constraint" then
									val:SetParent(newent)
								elseif const.Type == "PartCtrl_SpecialEffect" then
									val:SetParent(newent)
									val:SetSpecialEffectParent(newent)
								end
								self:DontDeleteOnRemove(val)
							end
						end

						local entstab = {}

						//Also switch over any instances of us to newent inside the entity subtable
						for tabnum, tab in pairs (const.Entity) do
							if tab.Entity and tab.Entity == self then 
								const.Entity[tabnum].Entity = newent
								const.Entity[tabnum].Index = newent:EntIndex()
							end
							entstab[const.Entity[tabnum].Index] = const.Entity[tabnum].Entity
						end

						if const.Type == "PartCtrl_Ent" or const.Type == "PartCtrl_SpecialEffect" and IsValid(const.Ent1) then
							self:DontDeleteOnRemove(const.Ent1) //Make sure we also clear deleteonremove for unparented cpoints
						end

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

			self:Remove()

			return newent
		end	

	end


	function ENT:Think()

		//If we had to give our parent entity a placeholder name to get our lighting origin to work properly (see advbonemerge constraint function), then remove it here
		local parent = self:GetParent()
		if IsValid(parent) and parent.AdvBone_PlaceholderName then
			parent:SetName("")
			parent.AdvBone_PlaceholderName = nil
		end


		//Detect whether we're in the 3D skybox, and network that to clients to use in the Draw function because they can't detect it themselves
		//(sky_camera ent is serverside only and ent:IsEFlagSet(EFL_IN_SKYBOX) always returns false)
		local skycamera = ents.FindByClass("sky_camera")
		if istable(skycamera) then skycamera = skycamera[1] end
		if IsValid(skycamera) then
			local inskybox = self:TestPVS(skycamera)
			if self:GetNWBool("IsInSkybox") != inskybox then
				self:SetNWBool("IsInSkybox", inskybox)
			end
		end

	end

end




if SERVER then
	//When NPCs die and create a serverside ragdoll, then transfer over advbonemerged ents to the ragdoll
	//TODO: can we do a clientside version of this for clientside ragdolls? spawn a clientside model that inherits our BuildBonePositions func or something like that?
	hook.Add("CreateEntityRagdoll", "AdvBone_CreateEntityRagdoll", function(oldent, rag)
		local oldentconsts = constraint.GetTable(oldent)
		for k, const in pairs (oldentconsts) do
			if const.Entity then
				if const.Type == "AdvBoneMerge" then
					//If any of the values in the constraint table are oldent, switch them over to the prop
					for key, val in pairs (const) do
						if val == oldent then 
							const[key] = rag
						end
					end

					local entstab = {}

					//Also switch over any instances of oldent to rag inside the entity subtable
					for tabnum, tab in pairs (const.Entity) do
						if tab.Entity and tab.Entity == oldent then 
							const.Entity[tabnum].Entity = rag
							const.Entity[tabnum].Index = rag:EntIndex()
						end
						entstab[const.Entity[tabnum].Index] = const.Entity[tabnum].Entity
					end

					//Now copy the constraint over to the ragdoll
					duplicator.CreateConstraintFromTable(const, entstab)
				end
			end
		end
	end)
end




duplicator.RegisterEntityClass("ent_advbonemerge", function(ply, data)

	local dupedent = ents.Create("ent_advbonemerge")
	if (!dupedent:IsValid()) then return false end

	//NOTE: We rely on our own bonemanip system to store the values instead of garrymanips, because garrymanips mess up renderbounds and cap pos/scale values -
	//however, we still save them in data.BoneManip (when the entity is saved) and load them from data.BoneManip (with duplicator.DoGeneric)
	dupedent.AdvBone_BoneManips = {}
	dupedent.AdvBone_BoneManips_DontNetwork = true //the entity hasn't been initialized on clients yet, so don't network the manips yet - they'll handle it themselves once they're ready

	//duplicator.GenericDuplicatorFunction(ply, data)
	duplicator.DoGeneric(dupedent, data)
	duplicator.DoGenericPhysics(dupedent, ply, data)

	dupedent.AdvBone_BoneManips_DontNetwork = nil
	dupedent.AdvBone_BoneInfo = data.AdvBone_BoneInfo
	dupedent.AdvBone_BoneInfo_IsDefault = false
	//Fix for old dupes - if the model has since been updated to have more bones than it does now, then create default BoneInfo entries so that we won't get any errors
	//(the dupes will still be horribly broken since the bone indices won't match up any more, but there's not a whole lot we can do about that, short of writing 
	//our own bonemanip system for pos/ang/scale instead of using garry's, one that uses bone name strings instead of bone index numbers for the table keys)
	if dupedent.AdvBone_BoneInfo then
		for i = -1, dupedent:GetBoneCount() - 1 do
			if dupedent.AdvBone_BoneInfo[i] == nil and (dupedent:GetBoneName(i) != "__INVALIDBONE__" or i == -1) then
				//MsgN("added missing boneinfo entry for bone #" .. i .. " (" .. dupedent:GetBoneName(i) .. ")")
				dupedent.AdvBone_BoneInfo[i] = {
					parent = "",
					scale = true,
				}
			end
		end
	end

	local unmergeinfo = data.AdvBone_UnmergeInfo
	dupedent.AdvBone_UnmergeInfo = unmergeinfo  //yeah, i'm not totally sure why this is necessary, but if we don't do this, it won't retrieve the table correctly or something

	dupedent:SetNWBool("DisableBeardFlexifier", data.DisableBeardFlexifier)

	dupedent:Spawn()
	dupedent:Activate() 

	return dupedent

end, "Data")











//FUNCTION REDIRECTS:
//We need our own separate system for bone manips for two reasons:
//1: Garrymanips cap position and scale vectors at a max distance of 128 and 32 respectively. We don't want this, we want pos and scale manips to be uncapped so players 
//   aren't limited in what they can create.
//2: Garrymanips try to assert their own render bounds, which we can only get around by rendering the entity twice and impacting framerate. If we handle all the manips
//   ourselves, garrymanips won't activate and cause problems.

local meta = FindMetaTable("Entity")

//When an entity is bonemanipped, wake up the BuildBonePositions function of itself and/or any ents advbonemerged to it
AdvBone_ResetBoneChangeTimeOnChildren = function(ent, networking) //global func so animprop code can use it
	if CLIENT then
		for _, ent2 in pairs (ent:GetChildren()) do
			if ent2.AdvBone_BoneManips then
				ent2.LastBoneChangeTime = CurTime()
				AdvBone_ResetBoneChangeTimeOnChildren(ent2)
			end
		end
	elseif networking then
		//Limit how often the server sends this to clients; multiple bone manips at once or ragdoll movements i.e. Stop Motion Helper will run this several times per frame
		//TODO: can we delay this longer? the client waits until 10 *frames* after LastBoneChangeTime to let BuildBonePositions fall asleep, which of course isn't consistent with server 
		//tickrate at all, so i don't know how we'd add any more of a delay without potentially breaking things for players with an insanely high framerate.
		local time = CurTime()
		ent.AdvBone_ResetBoneChangeTimeOnChildren_LastSent = ent.AdvBone_ResetBoneChangeTimeOnChildren_LastSent or time
		if time > ent.AdvBone_ResetBoneChangeTimeOnChildren_LastSent then
			ent.AdvBone_ResetBoneChangeTimeOnChildren_LastSent = time
			net.Start("AdvBone_ResetBoneChangeTimeOnChildren_SendToCl", true)
				net.WriteEntity(ent)
			net.Broadcast()
		end
	end
end

if SERVER then
	util.AddNetworkString("AdvBone_ResetBoneChangeTimeOnChildren_SendToCl")
else
	net.Receive("AdvBone_ResetBoneChangeTimeOnChildren_SendToCl", function()
		local ent = net.ReadEntity()
		if IsValid(ent) then
			AdvBone_ResetBoneChangeTimeOnChildren(ent)
		end
	end)
end

//Position functions
local old_ManipulateBonePosition = meta.ManipulateBonePosition
if old_ManipulateBonePosition then
	function meta.ManipulateBonePosition(ent, boneID, pos, networking, ...)
		if isentity(ent) and IsValid(ent) then
			local networking2 = networking //local var here so we send the original nil value to the old_ func
			if networking2 == nil then networking2 = true end

			if ent.AdvBone_BoneManips then
				if SERVER and networking2 and !ent.AdvBone_BoneManips_DontNetwork and pos != ent:GetManipulateBonePosition(boneID) then
					net.Start("AdvBone_BoneManipPos_SendToCl")
						net.WriteEntity(ent)
						net.WriteInt(boneID, 9)
						net.WriteVector(pos)
					net.Broadcast()
				end

				ent.AdvBone_BoneManips[boneID] = ent.AdvBone_BoneManips[boneID] or {}
				ent.AdvBone_BoneManips[boneID].p = pos
				if CLIENT then ent.LastBoneChangeTime = CurTime() end
			end
			AdvBone_ResetBoneChangeTimeOnChildren(ent, networking2)
		end
		if !(ent:GetClass() == "ent_advbonemerge" or ent:GetClass() == "prop_animated") then
			return old_ManipulateBonePosition(ent, boneID, pos, networking, ...)  //this doesn't usually return anything, but it's possible some other addon has overriden the function
		end									      //so it does, so let it return just in case
	end
end

if SERVER then
	util.AddNetworkString("AdvBone_BoneManipPos_SendToCl")
else
	net.Receive("AdvBone_BoneManipPos_SendToCl", function()
		local ent = net.ReadEntity()
		local boneID = net.ReadInt(9)
		local pos = net.ReadVector()

		if IsValid(ent) then
			ent:ManipulateBonePosition(boneID, pos)
		end
	end)
end

local old_GetManipulateBonePosition = meta.GetManipulateBonePosition
if old_GetManipulateBonePosition then
	function meta.GetManipulateBonePosition(ent, boneID, ...)
		if isentity(ent) and IsValid(ent) and ent.AdvBone_BoneManips and ent.AdvBone_BoneManips[boneID] and ent.AdvBone_BoneManips[boneID].p then
			return ent.AdvBone_BoneManips[boneID].p
		else
			return old_GetManipulateBonePosition(ent, boneID, ...)
		end
	end
end




//Angle functions
local old_ManipulateBoneAngles = meta.ManipulateBoneAngles
if old_ManipulateBoneAngles then
	function meta.ManipulateBoneAngles(ent, boneID, ang, networking, ...)
		if isentity(ent) and IsValid(ent) then
			local networking2 = networking //local var here so we send the original nil value to the old_ func
			if networking2 == nil then networking2 = true end

			if ent.AdvBone_BoneManips then
				if SERVER and networking2 and !ent.AdvBone_BoneManips_DontNetwork and ang != ent:GetManipulateBoneAngles(boneID) then
					net.Start("AdvBone_BoneManipAng_SendToCl")
						net.WriteEntity(ent)
						net.WriteInt(boneID, 9)
						net.WriteAngle(ang)
					net.Broadcast()
				end

				ent.AdvBone_BoneManips[boneID] = ent.AdvBone_BoneManips[boneID] or {}
				ent.AdvBone_BoneManips[boneID].a = ang
				if CLIENT then ent.LastBoneChangeTime = CurTime() end
			end
			AdvBone_ResetBoneChangeTimeOnChildren(ent, networking2)
		end
		if !(ent:GetClass() == "ent_advbonemerge" or ent:GetClass() == "prop_animated") then
			return old_ManipulateBoneAngles(ent, boneID, ang, networking, ...)  //this doesn't usually return anything, but it's possible some other addon has overriden the function
		end									    //so it does, so let it return just in case
	end
end

if SERVER then
	util.AddNetworkString("AdvBone_BoneManipAng_SendToCl")
else
	net.Receive("AdvBone_BoneManipAng_SendToCl", function()
		local ent = net.ReadEntity()
		local boneID = net.ReadInt(9)
		local ang = net.ReadAngle()

		if IsValid(ent) then
			ent:ManipulateBoneAngles(boneID, ang)
		end
	end)
end

local old_GetManipulateBoneAngles = meta.GetManipulateBoneAngles
if old_GetManipulateBoneAngles then
	function meta.GetManipulateBoneAngles(ent, boneID, ...)
		if isentity(ent) and IsValid(ent) and ent.AdvBone_BoneManips and ent.AdvBone_BoneManips[boneID] and ent.AdvBone_BoneManips[boneID].a then
			return ent.AdvBone_BoneManips[boneID].a
		else
			return old_GetManipulateBoneAngles(ent, boneID, ...)
		end
	end
end




//Scale functions
local old_ManipulateBoneScale = meta.ManipulateBoneScale
if old_ManipulateBoneScale then
	function meta.ManipulateBoneScale(ent, boneID, scale, ...)
		if isentity(ent) and IsValid(ent) then
			if ent.AdvBone_BoneManips then
				//ManipulateBoneScale has no "networking" arg, confirmed through testing 1/1/23
				if SERVER and !ent.AdvBone_BoneManips_DontNetwork and scale != ent:GetManipulateBoneScale(boneID) then
					net.Start("AdvBone_BoneManipScale_SendToCl")
						net.WriteEntity(ent)
						net.WriteInt(boneID, 9)
						net.WriteVector(scale)
					net.Broadcast()
				end
				
				ent.AdvBone_BoneManips[boneID] = ent.AdvBone_BoneManips[boneID] or {}
				ent.AdvBone_BoneManips[boneID].s = scale
				if CLIENT then ent.LastBoneChangeTime = CurTime() end
			end
			AdvBone_ResetBoneChangeTimeOnChildren(ent, true)
		end
		//if !(ent:GetClass() == "ent_advbonemerge" or ent:GetClass() == "prop_animated") then
		if !(ent:GetClass() == "ent_advbonemerge" or (ent:GetClass() == "prop_animated" and ent:GetBoneName(boneID) != "static_prop")) then  //static_prop animprops should still use garrymanips for scale
			return old_ManipulateBoneScale(ent, boneID, scale, ...)  //this doesn't usually return anything, but it's possible some other addon has overriden the function
		end								 //so it does, so let it return just in case
	end
end

if SERVER then
	util.AddNetworkString("AdvBone_BoneManipScale_SendToCl")
else
	net.Receive("AdvBone_BoneManipScale_SendToCl", function()
		local ent = net.ReadEntity()
		local boneID = net.ReadInt(9)
		local scale = net.ReadVector()

		if IsValid(ent) then
			ent:ManipulateBoneScale(boneID, scale)
		end
	end)
end

local old_GetManipulateBoneScale = meta.GetManipulateBoneScale
if old_GetManipulateBoneScale then
	function meta.GetManipulateBoneScale(ent, boneID, ...)
		if isentity(ent) and IsValid(ent) and ent.AdvBone_BoneManips and ent.AdvBone_BoneManips[boneID] and ent.AdvBone_BoneManips[boneID].s then
			return ent.AdvBone_BoneManips[boneID].s
		else
			return old_GetManipulateBoneScale(ent, boneID, ...)
		end
	end
end




//Misc.
local old_HasBoneManipulations = meta.HasBoneManipulations
if old_HasBoneManipulations then
	function meta.HasBoneManipulations(ent, ...)
		if isentity(ent) and IsValid(ent) and ent.AdvBone_BoneManips then
			return table.Count(ent.AdvBone_BoneManips) > 0
		else
			return old_HasBoneManipulations(ent, ...)
		end
	end
end




//Also wake up the BuildBonePositions function when changing the angle of an entity's physobjs. This fixes small rotations done with the Ragdoll Mover tool not waking up things advhonemerged to it.
//Currently only doing this for SetAngles and not SetPos because it doesn't seem to be necessary.

local meta = FindMetaTable("PhysObj")

local old_SetAngles = meta.SetAngles
if old_SetAngles then
	function meta.SetAngles(physobj, angles, ...)
		if IsValid(physobj) and physobj.GetEntity then
			local ent = physobj:GetEntity()
			if IsValid(ent) then
				AdvBone_ResetBoneChangeTimeOnChildren(ent, true)
			end
		end
		return old_SetAngles(physobj, angles, ...)  //this doesn't usually return anything, but it's possible some other addon has overriden the function
	end						    //so it does, so let it return just in case
end




//As it turns out, the game absolutely WILL store and even network ent:ManipulateBoneX(-1) (what we use for model origin manips) even though it's not a valid bone. 
//However, entity saving glosses over it since it only searches bones 0 and onward, so we have to save the information ourselves:

function ENT:OnEntityCopyTableFinish(data)

	data.BoneManip = data.BoneManip or {}

	local t = {}
			
	local s = self:GetManipulateBoneScale(-1)
	local a = self:GetManipulateBoneAngles(-1)
	local p = self:GetManipulateBonePosition(-1)
			
	if ( s != Vector(1, 1, 1) ) then t[ 's' ] = s end //scale
	if ( a != angle_zero ) then t[ 'a' ] = a end //angle
	if ( p != vector_origin ) then t[ 'p' ] = p end //position
		
	if ( table.Count( t ) > 0 ) then
		data.BoneManip[-1] = t
	end


	data.AdvBone_BoneManips = nil //don't save this table, everything in it has already been saved in Data.BoneManip by the duplicator save function


	//Store DisableBeardFlexifier nwbool
	data.DisableBeardFlexifier = self:GetNWBool("DisableBeardFlexifier")

end